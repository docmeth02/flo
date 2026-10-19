//
//  Thumbnail.swift
//  Ownwave
//

import ImageIO
import UniformTypeIdentifiers

/// Small copies of covers for the watch and the widgets, decoded at their
/// size rather than in full.
enum Thumbnail {
  /// Writes `source` scaled to at most `pixels` on its long side; false when
  /// it could not be read or written. Call off the main thread.
  static func write(
    _ source: URL, to target: URL, pixels: Int, type: UTType, quality: Double? = nil
  ) -> Bool {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil)
      .flatMap({ CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) })
    else { return false }
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
