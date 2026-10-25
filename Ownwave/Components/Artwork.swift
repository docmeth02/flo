//
//  Artwork.swift
//  Ownwave
//

import SwiftUI

/// An album's cover from the download or the cover cache, decoded off the
/// main thread at the size it is shown; a note glyph while it loads or when
/// there is none. A row lets go of its bitmap when it scrolls away, and
/// `CoverArt.thumbnails` keeps the recent ones within a memory budget.
struct CoverArt: View {
  let albumId: String
  /// A local path for a downloaded album, else empty.
  var url: String = ""
  /// Another cover the server keeps under `albumId`, as a playlist's.
  var artId: String?
  var radius: CGFloat = 8

  @Environment(\.palette) private var palette
  @Environment(\.displayScale) private var scale
  @State private var side: CGFloat = 0
  // Remembered with the album it is for, so a reused view never shows the
  // previous album's cover.
  @State private var loaded: (key: String, image: UIImage?)?

  private static let thumbnails: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 64 << 20
    return cache
  }()

  /// The album and the pixel size, rounded up so a few points of layout do
  /// not decode it again.
  private var key: String {
    let pixels = Int((side * scale / 64).rounded(.up)) * 64
    return "\(albumId)@\(pixels)"
  }

  var body: some View {
    Color.clear
      .overlay {
        if let image = loaded?.key == key ? loaded?.image : nil {
          Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
          palette.surface2
            .overlay {
              Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(palette.secondary)
            }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onGeometryChange(for: CGFloat.self) {
        max($0.size.width, $0.size.height)
      } action: {
        side = $0
      }
      .task(id: key) {
        guard !albumId.isEmpty, side > 0, loaded?.key != key else { return }
        let key = key
        if let cached = Self.thumbnails.object(forKey: key as NSString) {
          loaded = (key, cached)
          return
        }
        let pixels = Int(side * scale)
        let path = await CoverTint.coverFile(albumId: albumId, url: url, artId: artId)
        let cgImage = await Task.detached(priority: .userInitiated) {
          path.flatMap { Thumbnail.image(URL(fileURLWithPath: $0), pixels: pixels) }
        }.value
        guard !Task.isCancelled else { return }
        let image = cgImage.map(UIImage.init(cgImage:))
        if let image, let cgImage {
          Self.thumbnails.setObject(
            image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        }
        loaded = (key, image)
      }
      .onDisappear { loaded = nil }
  }
}

/// An accent glyph on a tile: artists and radios round, playlists square.
struct GlyphTile: View {
  let systemImage: String
  var round = false
  var radius: CGFloat = 10

  @Environment(\.palette) private var palette

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      palette.surface2
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: side * 0.42, weight: .medium))
            .foregroundStyle(palette.accent)
        }
        .clipShape(RoundedRectangle(cornerRadius: round ? side / 2 : radius, style: .continuous))
    }
  }

  static let artist = GlyphTile(systemImage: "music.mic", round: true)
  static let playlist = GlyphTile(systemImage: "music.note.list")
  static let radio = GlyphTile(systemImage: "dot.radiowaves.up.forward", round: true)

  /// The same glyph on a square tile, for the larger tiles of pins and the
  /// playlist screen.
  func squared(radius: CGFloat) -> GlyphTile {
    GlyphTile(systemImage: systemImage, radius: radius)
  }
}
