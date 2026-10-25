//
//  StorageUsage.swift
//  flo
//

import Foundation

/// What the stream cache and the downloads take on the device, and the room
/// left, as Settings and the Downloads card show it.
struct StorageUsage: Equatable {
  var cache: Int64 = 0
  var downloads: Int64 = 0
  var free: Int64 = 0

  var used: Int64 { cache + downloads }

  /// The part `bytes` is of the cache, the downloads and the room left
  /// together, 0 while nothing is known.
  func share(of bytes: Int64) -> Double {
    let total = used + free
    return total > 0 ? Double(bytes) / Double(total) : 0
  }

  /// Reads the sizes off the main thread.
  static func measure() async -> StorageUsage {
    async let cache = StreamCacheManager.shared.calculateCacheSize()
    async let downloads = LocalFileManager.shared.downloadsBytes()
    async let free = Task.detached(priority: .userInitiated) { freeBytes() }.value
    return await StorageUsage(cache: cache, downloads: downloads, free: free)
  }

  /// The room left on the device. The file system's free size: the volume's
  /// available capacity can be negative on watchOS, and its important-usage
  /// figure does not exist there.
  static func freeBytes() -> Int64 {
    let system = try? FileManager.default.attributesOfFileSystem(
      forPath: URL.documentsDirectory.path)
    return max(0, (system?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
  }
}
