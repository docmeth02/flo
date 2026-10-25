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

  /// Reads the sizes off the main thread.
  static func measure() async -> StorageUsage {
    async let cache = StreamCacheManager.shared.calculateCacheSize()
    async let downloads = LocalFileManager.shared.downloadsBytes()
    async let free = Task.detached(priority: .userInitiated) { AppPlatform.freeBytes() }.value
    return await StorageUsage(cache: cache, downloads: downloads, free: free)
  }

  /// The widths of a bar's parts, each its share of the parts together, in
  /// `width` with `gap` between them. A small part stays `minimum` wide, so
  /// it shows; the widest gives up that room.
  static func barWidths(
    _ parts: [Int64], in width: Double, gap: Double, minimum: Double
  ) -> [Double] {
    let total = parts.reduce(0, +)
    let room = width - gap * Double(max(parts.count - 1, 0))
    guard total > 0, room > 0 else { return parts.map { _ in 0 } }
    var widths = parts.map { max(minimum, room * Double($0) / Double(total)) }
    if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
      widths[widest] = max(0, widths[widest] - (widths.reduce(0, +) - room))
    }
    return widths
  }
}
