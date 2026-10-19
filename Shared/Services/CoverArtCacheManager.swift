//
//  CoverArtCacheManager.swift
//  flo
//

import Foundation

class CoverArtCacheManager {
  static let shared = CoverArtCacheManager()

  private let fileManager = FileManager.default
  private let cacheDirectory = URL.cacheDirectory(named: "CoverArtCache")
  private var downloads: [String: Task<String?, Never>] = [:]
  private let syncQueue = DispatchQueue(label: "flo.coverartcache")

  private init() {}

  func cachedFilePath(albumId: String) -> String? {
    let file = fileURL(albumId: albumId)
    guard fileManager.fileExists(atPath: file.path) else { return nil }
    return file.path
  }

  /// Local path of the album's cover, downloading it first when needed; nil
  /// when that failed. Concurrent callers for the same album share one
  /// download.
  func coverPath(albumId: String) async -> String? {
    guard !albumId.isEmpty else { return nil }

    let download = syncQueue.sync { () -> Task<String?, Never>? in
      if cachedFilePath(albumId: albumId) != nil { return nil }
      if let running = downloads[albumId] { return running }
      let task = Task { await self.download(albumId: albumId) }
      downloads[albumId] = task
      return task
    }
    guard let download else { return cachedFilePath(albumId: albumId) }
    return await download.value
  }

  private func download(albumId: String) async -> String? {
    let params: [String: Any] = ["id": "al-\(albumId)", "size": AppPlatform.coverArtSize]
    if let tempFile = try? await APIManager.shared.subsonicDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params)
    {
      let target = fileURL(albumId: albumId)
      try? fileManager.removeItem(at: target)
      try? fileManager.moveItem(at: tempFile, to: target)
    }
    // A logout cancelled it, and a newer download may hold its place.
    if !Task.isCancelled { syncQueue.sync { downloads[albumId] = nil } }
    return cachedFilePath(albumId: albumId)
  }

  func clearCache() {
    syncQueue.sync {
      downloads.values.forEach { $0.cancel() }
      downloads.removeAll()
    }
    try? fileManager.removeItem(at: cacheDirectory)
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  }

  private func fileURL(albumId: String) -> URL {
    cacheDirectory.appendingPathComponent("\(albumId).img")
  }
}
