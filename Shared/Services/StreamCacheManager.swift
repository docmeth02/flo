//
//  StreamCacheManager.swift
//  flo
//

import Alamofire
import CoreData
import Foundation

class StreamCacheManager {
  static let shared = StreamCacheManager()

  /// A size limit Settings offers for the cache; 0 turns it off.
  struct Limit {
    let bytes: Int64
    let label: String
  }

  /// The limits Settings offers, up to what the device has room for.
  static let cacheLimits = [
    Limit(bytes: 0, label: "Off"),
    Limit(bytes: 262_144_000, label: "250 MB"),
    Limit(bytes: 524_288_000, label: "500 MB"),
    Limit(bytes: 1_073_741_824, label: "1 GB"),
    Limit(bytes: 2_147_483_648, label: "2 GB"),
    Limit(bytes: 5_368_709_120, label: "5 GB"),
  ].filter { $0.bytes <= AppPlatform.largestStreamCache }

  private let fileManager = FileManager.default
  private let cacheDirectory = URL.cacheDirectory(named: "StreamCache")
  private let syncQueue = DispatchQueue(label: "flo.streamcache")
  // The attempt each cache key is in flight with. A key cancelled and asked
  // for again gets a new attempt, so the old one's late completion leaves the
  // new one's registration and record alone.
  private var inFlightAttempts: [String: UUID] = [:]
  private var inFlightDownloads: [String: DownloadRequest] = [:]
  private var currentlyPlayingSongId: String?

  /// CacheEntity.state.
  private enum State: String {
    case downloading, ready
  }

  private init() {}

  // MARK: - Public API

  func cachedFileURL(mediaFileId: String) -> URL? {
    let bitrate = TranscodingSettings.streamingBitRate
    if let bitrate {
      let key = cacheKey(mediaFileId: mediaFileId, bitrate: bitrate)
      let exact = CoreDataManager.shared.getRecordByKey(
        entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1
      ).first
      if let exact, let url = readyFileURL(for: exact) {
        return url
      }
    }

    // Without the server, or without streaming on this network, a copy cached
    // at another bitrate beats no playback.
    guard !ConnectivityMonitor.shared.canReachServer || bitrate == nil else { return nil }

    return CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.mediaFileId, value: mediaFileId
    )
    .lazy.compactMap { self.readyFileURL(for: $0) }.first
  }

  /// The file of a ready cache record, refreshing its access time; records
  /// whose file vanished are dropped.
  private func readyFileURL(for record: CacheEntity) -> URL? {
    guard record.state == State.ready.rawValue, let filePath = record.filePath else { return nil }

    let fileURL = cacheDirectory.appendingPathComponent(filePath)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      CoreDataManager.shared.viewContext.delete(record)
      CoreDataManager.shared.saveRecord()
      return nil
    }

    record.lastAccessedAt = Date()
    CoreDataManager.shared.saveRecord()

    return fileURL
  }

  /// Drops the cached copy at `fileURL`, which failed to play and would fail
  /// again on every later play. Main thread; a file outside the cache, such
  /// as a download, is left alone.
  func evict(fileURL: URL) {
    guard fileURL.deletingLastPathComponent().path == cacheDirectory.path else { return }
    try? fileManager.removeItem(at: fileURL)
    removeCacheRecord(key: fileURL.deletingPathExtension().lastPathComponent)
  }

  func cacheSong(mediaFileId: String, originalSuffix: String? = nil, from queueItem: QueueEntity? = nil) {
    guard UserDefaultsManager.streamCacheMaxSize > 0 else { return }
    guard !mediaFileId.isEmpty else { return }
    guard ConnectivityMonitor.shared.isOnline else { return }
    // A downloaded song already plays from disk; caching it again would spend
    // storage and radio time on a second copy.
    guard AlbumService.shared.downloadedFileURL(mediaFileId: mediaFileId) == nil else { return }

    guard let bitrate = TranscodingSettings.streamingBitRate else { return }
    let key = cacheKey(mediaFileId: mediaFileId, bitrate: bitrate)

    let attempt = UUID()
    let didRegister: Bool = syncQueue.sync {
      guard inFlightAttempts[key] == nil else { return false }
      inFlightAttempts[key] = attempt
      return true
    }
    guard didRegister else { return }

    let existing = CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1)
    if !existing.isEmpty {
      endAttempt(attempt, key: key)
      return
    }

    // The record is made now, while the queue item behind the metadata is
    // alive; the file name waits for the server's transcode decision.
    let entity = CacheEntity(context: CoreDataManager.shared.viewContext)
    entity.cacheKey = key
    entity.mediaFileId = mediaFileId
    entity.state = State.downloading.rawValue
    entity.cachedAt = Date()
    entity.lastAccessedAt = Date()
    entity.fileSize = 0

    // The cached songs list shows the song offline.
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
      let result = await AlbumService.shared.resolveStreamSource(
        songId: mediaFileId, originalSuffix: originalSuffix, offset: 0)
      guard case .success(let source) = result else {
        if self.endAttempt(attempt, key: key) { self.removeCacheRecord(key: key) }
        return
      }
      // A cancel while the decision was pending already removed the record.
      guard self.syncQueue.sync(execute: { self.inFlightAttempts[key] == attempt }) else { return }
      self.startCacheDownload(key: key, attempt: attempt, source: source)
    }
  }

  private func startCacheDownload(key: String, attempt: UUID, source: StreamSource) {
    let suffix = source.suffix
    if let record = CoreDataManager.shared.getRecordByKey(
      entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1
    ).first {
      record.filePath = "\(key).\(suffix)"
      record.suffix = suffix
      CoreDataManager.shared.saveRecord()
    }

    let request = APIManager.shared.subsonicDownload(
      endpoint: source.endpoint, parameters: source.parameters,
      allowsCellular: TranscodingSettings.streamsOverCellular
    ) { [weak self] result in
      guard let self = self else { return }
      // A cancelled attempt's record is gone, or is the next attempt's.
      guard self.endAttempt(attempt, key: key) else {
        if case .success(let tempFile) = result { try? self.fileManager.removeItem(at: tempFile) }
        return
      }

      switch result {
      case .success(let tempFile):
        let target = self.cacheDirectory.appendingPathComponent("\(key).\(suffix)")

        guard (try? LocalFileManager.shared.moveFile(source: tempFile, target: target)) != nil else {
          DispatchQueue.main.async { self.removeCacheRecord(key: key) }
          return
        }
        let fileSize =
          (try? self.fileManager.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0

        DispatchQueue.main.async {
          let records = CoreDataManager.shared.getRecordByKey(
            entity: CacheEntity.self, key: \CacheEntity.cacheKey, value: key, limit: 1)
          if let record = records.first {
            record.state = State.ready.rawValue
            record.fileSize = fileSize
            CoreDataManager.shared.saveRecord()
          }

          self.evictIfNeeded()
        }

      case .failure:
        DispatchQueue.main.async { self.removeCacheRecord(key: key) }
      }
    }

    syncQueue.sync {
      // A cancel may have come while the request was set up.
      if inFlightAttempts[key] == attempt {
        inFlightDownloads[key] = request
      } else {
        request.cancel()
      }
    }
  }

  /// Ends the attempt; false when it was cancelled or replaced meanwhile.
  @discardableResult
  private func endAttempt(_ attempt: UUID, key: String) -> Bool {
    syncQueue.sync {
      guard inFlightAttempts[key] == attempt else { return false }
      inFlightAttempts[key] = nil
      inFlightDownloads[key] = nil
      return true
    }
  }

  func getCachedSongs() -> [Song] {
    let sortDescriptor = NSSortDescriptor(key: "lastAccessedAt", ascending: false)
    let records = CoreDataManager.shared.getRecordsByEntity(
      entity: CacheEntity.self, sortDescriptors: [sortDescriptor])

    // The most recently played copy of each song.
    var seen = Set<String>()
    return records
      .filter { $0.state == State.ready.rawValue && $0.title != nil }
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
    // Without streaming on this network none of them is kept.
    let kept = TranscodingSettings.streamingBitRate.map { bitrate in
      Set(mediaFileIds.map { cacheKey(mediaFileId: $0, bitrate: bitrate) })
    } ?? []
    for key in cancelDownloads(keeping: kept) {
      removeCacheRecord(key: key)
    }
  }

  /// Cancels the attempts in flight, downloading or waiting for the server's
  /// decision, except those of the `kept` cache keys, and returns the
  /// cancelled keys.
  @discardableResult
  private func cancelDownloads(keeping kept: Set<String> = []) -> [String] {
    syncQueue.sync {
      let keys = inFlightAttempts.keys.filter { !kept.contains($0) }
      for key in keys {
        inFlightAttempts[key] = nil
        inFlightDownloads.removeValue(forKey: key)?.cancel()
      }
      return keys
    }
  }

  /// Main thread. Off empties the cache, a lower limit trims it at once.
  func setLimit(_ bytes: Int64) {
    UserDefaultsManager.streamCacheMaxSize = bytes
    if bytes == 0 { clearCache() } else { evictIfNeeded() }
  }

  /// Main thread; the cache is empty on return.
  func clearCache() {
    cancelDownloads()

    try? fileManager.removeItem(at: cacheDirectory)
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

    deleteAllCacheRecords()
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
      return records.filter { $0.state == State.ready.rawValue }.reduce(0) { $0 + $1.fileSize }
    }
  }

  func reconcile() {
    // The downloading records go below, so nothing may still be filling them.
    cancelDownloads()

    DispatchQueue.main.async { [self] in
      let records = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)

      for record in records {
        if record.state == State.downloading.rawValue {
          if let filePath = record.filePath {
            try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
          }
          CoreDataManager.shared.viewContext.delete(record)
          continue
        }

        if let filePath = record.filePath {
          let fileURL = cacheDirectory.appendingPathComponent(filePath)
          if !fileManager.fileExists(atPath: fileURL.path) {
            CoreDataManager.shared.viewContext.delete(record)
          }
        } else {
          CoreDataManager.shared.viewContext.delete(record)
        }
      }

      CoreDataManager.shared.saveRecord()

      // Files no record names are left over from interrupted downloads.
      let survivingRecords = CoreDataManager.shared.getRecordsByEntity(entity: CacheEntity.self)
      let knownFiles = Set(survivingRecords.compactMap { $0.filePath })

      if let files = try? fileManager.contentsOfDirectory(
        at: cacheDirectory, includingPropertiesForKeys: nil)
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
    // The view context is main-thread only.
    dispatchPrecondition(condition: .onQueue(.main))

    let maxSize = UserDefaultsManager.streamCacheMaxSize
    guard maxSize > 0 else { return }

    let sortDescriptor = NSSortDescriptor(key: "lastAccessedAt", ascending: true)
    let records = CoreDataManager.shared.getRecordsByEntity(
      entity: CacheEntity.self, sortDescriptors: [sortDescriptor])

    let totalSize = records.filter { $0.state == State.ready.rawValue }
      .reduce(Int64(0)) { $0 + $1.fileSize }
    guard totalSize > maxSize else { return }

    var currentSize = totalSize
    let currentlyPlaying: String? = syncQueue.sync { currentlyPlayingSongId }

    for record in records where record.state == State.ready.rawValue {
      guard currentSize > maxSize else { break }

      if let playing = currentlyPlaying, record.mediaFileId == playing { continue }

      let size = record.fileSize

      if let filePath = record.filePath {
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
      }

      CoreDataManager.shared.viewContext.delete(record)
      currentSize -= size
    }

    CoreDataManager.shared.saveRecord()
  }
}
