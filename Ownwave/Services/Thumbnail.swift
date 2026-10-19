//
//  Thumbnail.swift
//  Ownwave
//

import ImageIO
import UniformTypeIdentifiers

/// Covers decoded at the size they are shown or sent at rather than in full:
/// on screen, and as small copies for the watch and the widgets.
enum Thumbnail {
  /// `source` scaled to at most `pixels` on its long side; nil when it could
  /// not be read. Call off the main thread.
  static func image(_ source: URL, pixels: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateWithURL(source as CFURL, nil)
      .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
  }

  /// Writes `source` scaled to at most `pixels` on its long side; false when
  /// it could not be read or written. Call off the main thread.
  static func write(
    _ source: URL, to target: URL, pixels: Int, type: UTType, quality: Double? = nil
  ) -> Bool {
    guard let image = image(source, pixels: pixels) else { return false }
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      let destination = CGImageDestinationCreateWithURL(
        target as CFURL, type.identifier as CFString, 1, nil)
    else { return false }
    let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    return CGImageDestinationFinalize(destination)
  }
}
