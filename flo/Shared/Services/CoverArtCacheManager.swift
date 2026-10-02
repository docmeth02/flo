//
//  CoverArtCacheManager.swift
//  flo
//

import Foundation

class CoverArtCacheManager {
  static let shared = CoverArtCacheManager()

  private let fileManager = FileManager.default
  private let cacheDirectory: URL?
  private var inFlightIds: Set<String> = []
  private var waiters: [String: [(String?) -> Void]] = [:]
  private let syncQueue = DispatchQueue(label: "net.faultables.flo.coverartcache")

  private init() {
    self.cacheDirectory =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("CoverArtCache")

    if let dir = cacheDirectory, !fileManager.fileExists(atPath: dir.path) {
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  func cachedFilePath(albumId: String) -> String? {
    guard let dir = cacheDirectory else { return nil }
    let file = dir.appendingPathComponent("\(albumId).img")
    guard fileManager.fileExists(atPath: file.path) else { return nil }
    return file.path
  }

  /// Local path of the album's cover, downloading it first when needed.
  /// Concurrent callers for the same album share one download; the
  /// completion runs on an arbitrary queue and gets nil when it failed.
  func coverPath(albumId: String, completion: @escaping (String?) -> Void) {
    guard !albumId.isEmpty else { return completion(nil) }

    var cached: String?
    var shouldDownload = false
    syncQueue.sync {
      if let path = cachedFilePath(albumId: albumId) {
        cached = path
        return
      }
      waiters[albumId, default: []].append(completion)
      if !inFlightIds.contains(albumId) {
        inFlightIds.insert(albumId)
        shouldDownload = true
      }
    }
    if let cached { return completion(cached) }
    guard shouldDownload else { return }

    let params: [String: Any] = ["id": "al-\(albumId)", "size": API.coverArtSize]
    APIManager.shared.SubsonicEndpointDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params
    ) { [weak self] result in
      guard let self = self else { return }
      if case .success(let tempFile) = result, let dir = self.cacheDirectory {
        let target = dir.appendingPathComponent("\(albumId).img")
        try? self.fileManager.removeItem(at: target)
        try? self.fileManager.moveItem(at: tempFile, to: target)
      }

      var pending: [(String?) -> Void] = []
      self.syncQueue.sync {
        self.inFlightIds.remove(albumId)
        pending = self.waiters.removeValue(forKey: albumId) ?? []
      }
      let path = self.cachedFilePath(albumId: albumId)
      pending.forEach { $0(path) }
    }
  }

  func coverPath(albumId: String) async -> String? {
    await withCheckedContinuation { continuation in
      coverPath(albumId: albumId) { continuation.resume(returning: $0) }
    }
  }

  func clearCache() {
    syncQueue.sync { inFlightIds.removeAll() }
    guard let dir = cacheDirectory, fileManager.fileExists(atPath: dir.path) else { return }
    try? fileManager.removeItem(at: dir)
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
  }
}
