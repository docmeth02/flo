//
//  StreamCacheManager.swift
//  flo
//

import Alamofire
import CoreData
import Foundation

class StreamCacheManager {
  static let shared = StreamCacheManager()

  private let fileManager = FileManager.default
  private let cacheDirectory: URL?
  private let syncQueue = DispatchQueue(label: "net.faultables.flo.streamcache")
  private var inFlightDownloads: [String: DownloadRequest] = [:]
  private var inFlightProgress: [String: Double] = [:]
  private var inFlightKeys: Set<String> = []
  private var currentlyPlayingSongId: String?

  private init() {
    self.cacheDirectory =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("StreamCache")

    if let dir = cacheDirectory, !fileManager.fileExists(atPath: dir.path) {
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  // MARK: - Public API

  func cachedFileURL(mediaFileId: String) -> URL? {
    let bitrate = UserDefaultsManager.maxBitRate
    let key = cacheKey(mediaFileId: mediaFileId, bitrate: bitrate)

    let exact = CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1
    ).first
    if let exact, let url = readyFileURL(for: exact) {
      return url
    }

    // Without the server, a copy cached at another bitrate beats no playback.
    guard !ConnectivityMonitor.shared.canReachServer else { return nil }

    return CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.mediaFileId, value: mediaFileId
    )
    .lazy.compactMap { self.readyFileURL(for: $0) }.first
  }

  /// The file of a ready cache record, refreshing its access time; records
  /// whose file vanished are dropped.
  private func readyFileURL(for record: CacheEntity) -> URL? {
    guard record.state == "ready", let filePath = record.filePath, let dir = cacheDirectory
    else { return nil }

    let fileURL = dir.appendingPathComponent(filePath)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      CoreDataManager.shared.viewContext.delete(record)
      CoreDataManager.shared.saveRecord()
      return nil
    }

    record.lastAccessedAt = Date()
    CoreDataManager.shared.saveRecord()

    return fileURL
  }


  func cacheSong(mediaFileId: String, originalSuffix: String? = nil, from queueItem: QueueEntity? = nil) {
    guard UserDefaultsManager.streamCacheMaxSize > 0 else { return }
    guard !mediaFileId.isEmpty else { return }
    guard ConnectivityMonitor.shared.isOnline else { return }
    // A downloaded song already plays from disk; caching it again would spend
    // storage and radio time on a second copy.
    guard AlbumService.shared.downloadedFileURL(mediaFileId: mediaFileId) == nil else { return }

    let bitrate = UserDefaultsManager.maxBitRate
    let key = cacheKey(mediaFileId: mediaFileId, bitrate: bitrate)

    // Register in-flight atomically — prevents duplicate downloads
    let didRegister: Bool = syncQueue.sync {
      guard !inFlightKeys.contains(key) else { return false }
      inFlightKeys.insert(key)
      return true
    }
    guard didRegister else { return }

    // Already cached?
    let existing = CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1)
    if !existing.isEmpty {
      syncQueue.async { self.inFlightKeys.remove(key) }
      return
    }

    // Create CacheEntity with downloading state now, while the queue item
    // behind the metadata is alive; the file name waits for the server's
    // transcode decision.
    let entity = CacheEntity(context: CoreDataManager.shared.viewContext)
    entity.cacheKey = key
    entity.mediaFileId = mediaFileId
    entity.state = "downloading"
    entity.cachedAt = Date()
    entity.lastAccessedAt = Date()
    entity.fileSize = 0

    // Store song metadata for offline browsing
    if let q = queueItem {
      entity.title = q.songName
      entity.artistName = q.artistName
      entity.albumId = q.albumId
      entity.albumName = q.albumName
      entity.duration = q.duration
      entity.bitRate = q.bitRate
      entity.sampleRate = q.sampleRate
      entity.explicitStatus = q.explicitStatus
    }

    CoreDataManager.shared.saveRecord()

    Task { @MainActor in
      let source = await AlbumService.shared.resolveStreamSource(
        songId: mediaFileId, originalSuffix: originalSuffix, offset: 0)
      // cancelAllInFlight may have run while the decision was pending.
      guard self.syncQueue.sync(execute: { self.inFlightKeys.contains(key) }) else {
        self.removeCacheRecord(key: key)
        return
      }
      self.startCacheDownload(key: key, source: source)
    }
  }

  private func startCacheDownload(key: String, source: StreamSource) {
    let suffix = source.suffix
    if let record = CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1
    ).first {
      record.filePath = "\(key).\(suffix)"
      record.suffix = suffix
      CoreDataManager.shared.saveRecord()
    }

    let progressUpdate: (Double) -> Void = { [weak self] progress in
      self?.syncQueue.async { self?.inFlightProgress[key] = progress / 100.0 }
    }

    let request = APIManager.shared.SubsonicEndpointDownload(
      endpoint: source.endpoint, parameters: source.parameters, progressUpdate: progressUpdate
    ) { [weak self] result in
      guard let self = self else { return }

      self.syncQueue.async {
        self.inFlightDownloads.removeValue(forKey: key)
        self.inFlightProgress.removeValue(forKey: key)
        self.inFlightKeys.remove(key)
      }

      switch result {
      case .success(let tempFile):
        guard let dir = self.cacheDirectory else {
          DispatchQueue.main.async { self.removeCacheRecord(key: key) }
          return
        }

        let target = dir.appendingPathComponent("\(key).\(suffix)")

        LocalFileManager.shared.moveFile(source: tempFile, target: target) { moveResult in
          switch moveResult {
          case .success:
            let fileSize =
              (try? self.fileManager.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0

            DispatchQueue.main.async {
              let records = CoreDataManager.shared.getRecordByKey(
                entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1)
              if let record = records.first {
                record.state = "ready"
                record.fileSize = fileSize
                CoreDataManager.shared.saveRecord()
              }

              self.evictIfNeeded()
            }

          case .failure:
            DispatchQueue.main.async { self.removeCacheRecord(key: key) }
          }
        }

      case .failure(let error):
        if let afError = error.asAFError, case .explicitlyCancelled = afError {
          // Cancelled — clean up
        }
        DispatchQueue.main.async { self.removeCacheRecord(key: key) }
      }
    }

    syncQueue.sync {
      if !inFlightKeys.contains(key) {
        // cancelAllInFlight ran while we were setting up — cancel immediately
        request.cancel()
      } else {
        self.inFlightDownloads[key] = request
      }
    }
  }

  func getCachedSongs() -> [Song] {
    let sortDescriptor = NSSortDescriptor(key: "lastAccessedAt", ascending: false)
    let records = CoreDataManager.shared.getRecordsByEntity(
      entity: CacheEntity.self, sortDescriptors: [sortDescriptor])

    // Deduplicate by mediaFileId (keep most recent per song)
    var seen = Set<String>()
    return records
      .filter { $0.state == "ready" && $0.title != nil }
      .filter { record in
        guard let id = record.mediaFileId else { return false }
        return seen.insert(id).inserted
      }
      .map { Song(from: $0) }
  }

  func setCurrentlyPlaying(mediaFileId: String) {
    syncQueue.async { self.currentlyPlayingSongId = mediaFileId }
  }

  /// Cancels the cache downloads in flight, except those of the given songs.
  func cancelAllInFlight(keeping mediaFileIds: Set<String> = []) {
    let bitrate = UserDefaultsManager.maxBitRate
    let kept = Set(mediaFileIds.map { cacheKey(mediaFileId: $0, bitrate: bitrate) })
    let keysToClean: [String] = syncQueue.sync {
      let keys = inFlightDownloads.keys.filter { !kept.contains($0) }
      for key in keys {
        inFlightDownloads.removeValue(forKey: key)?.cancel()
        inFlightProgress.removeValue(forKey: key)
      }
      inFlightKeys.formIntersection(kept)
      return keys
    }

    for key in keysToClean {
      removeCacheRecord(key: key)
    }

    // Clean up any orphan downloading records from the cancelled keys
    if !keysToClean.isEmpty {
      let keySet = Set(keysToClean)
      DispatchQueue.main.async {
        let records = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)
        let orphans = records.filter { $0.state == "downloading" && keySet.contains($0.cacheKey ?? "") }
        for record in orphans {
          CoreDataManager.shared.viewContext.delete(record)
        }
        if !orphans.isEmpty {
          CoreDataManager.shared.saveRecord()
        }
      }
    }
  }

  func clearCache() {
    // Cancel all downloads
    syncQueue.sync {
      for (_, request) in inFlightDownloads { request.cancel() }
      inFlightDownloads.removeAll()
      inFlightProgress.removeAll()
      inFlightKeys.removeAll()
    }

    // Delete all files
    if let dir = cacheDirectory, fileManager.fileExists(atPath: dir.path) {
      try? fileManager.removeItem(at: dir)
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // Delete all CacheEntity records (synchronous — callers expect cache to be clear on return)
    if Thread.isMainThread {
      deleteAllCacheRecords()
    } else {
      DispatchQueue.main.sync { deleteAllCacheRecords() }
    }
  }

  // A method rather than a closure: the Swift 6.4 optimizer crashes inlining
  // CoreDataManager's lazy container into the closure form in Release builds.
  @inline(never)
  private func deleteAllCacheRecords() {
    CoreDataManager.shared.batchDelete(entityName: "CacheEntity")
  }

  func calculateCacheSize() async -> Int64 {
    return await MainActor.run {
      let records = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)
      return records.filter { $0.state == "ready" }.reduce(0) { $0 + $1.fileSize }
    }
  }

  func reconcile() {
    // Cancel any active downloads first to prevent races
    syncQueue.sync {
      for (_, request) in inFlightDownloads { request.cancel() }
      inFlightDownloads.removeAll()
      inFlightProgress.removeAll()
      inFlightKeys.removeAll()
    }

    DispatchQueue.main.async { [self] in
      let records = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)

      for record in records {
        if record.state == "downloading" {
          if let filePath = record.filePath, let dir = cacheDirectory {
            let fileURL = dir.appendingPathComponent(filePath)
            try? fileManager.removeItem(at: fileURL)
          }
          CoreDataManager.shared.viewContext.delete(record)
          continue
        }

        if let filePath = record.filePath, let dir = cacheDirectory {
          let fileURL = dir.appendingPathComponent(filePath)
          if !fileManager.fileExists(atPath: fileURL.path) {
            CoreDataManager.shared.viewContext.delete(record)
          }
        } else {
          CoreDataManager.shared.viewContext.delete(record)
        }
      }

      CoreDataManager.shared.saveRecord()

      // Re-fetch surviving records for orphan file cleanup
      let survivingRecords = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)
      let knownFiles = Set(survivingRecords.compactMap { $0.filePath })

      if let dir = cacheDirectory,
        let files = try? fileManager.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil)
      {
        for file in files {
          if !knownFiles.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
          }
        }
      }
    }
  }

  // MARK: - Private

  private func cacheKey(mediaFileId: String, bitrate: String) -> String {
    return "\(mediaFileId)_\(bitrate)"
  }

  private func removeCacheRecord(key: String) {
    CoreDataManager.shared.deleteRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key)
  }

  private func evictIfNeeded() {
    // Must be called on main thread for CoreData viewContext safety
    dispatchPrecondition(condition: .onQueue(.main))

    let maxSize = UserDefaultsManager.streamCacheMaxSize
    guard maxSize > 0 else { return }

    let sortDescriptor = NSSortDescriptor(key: "lastAccessedAt", ascending: true)
    let records = CoreDataManager.shared.getRecordsByEntity(
      entity: CacheEntity.self, sortDescriptors: [sortDescriptor])

    let totalSize = records.filter { $0.state == "ready" }.reduce(Int64(0)) { $0 + $1.fileSize }
    guard totalSize > maxSize else { return }

    var currentSize = totalSize
    let currentlyPlaying: String? = syncQueue.sync { currentlyPlayingSongId }

    for record in records where record.state == "ready" {
      guard currentSize > maxSize else { break }

      if let playing = currentlyPlaying, record.mediaFileId == playing { continue }

      let size = record.fileSize

      if let filePath = record.filePath, let dir = cacheDirectory {
        let fileURL = dir.appendingPathComponent(filePath)
        try? fileManager.removeItem(at: fileURL)
      }

      CoreDataManager.shared.viewContext.delete(record)
      currentSize -= size
    }

    CoreDataManager.shared.saveRecord()
  }
}
