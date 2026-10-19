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
      .onGeometryChange(for: CGFloat.self) { max($0.size.width, $0.size.height) } action: {
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
        let path = await CoverTint.coverFile(albumId: albumId, url: url)
        let image = await Task.detached(priority: .userInitiated) {
          path.flatMap { Thumbnail.image(URL(fileURLWithPath: $0), pixels: pixels) }
            .map(UIImage.init(cgImage:))
        }.value
        guard !Task.isCancelled else { return }
        if let image, let cgImage = image.cgImage {
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
}

/// The colors the phone derives from a cover's hue, light and dark.
struct CoverShades {
  /// Text, icons and the Play fill.
  let tint: Color
  /// Behind tinted elements.
  let background: Color

  init(hue: Double, scheme: ColorScheme) {
    let dark = scheme == .dark
    tint = CoverTint.color(hue: hue, lightness: dark ? 0.86 : 0.48, chroma: dark ? 0.1 : 0.14)
    background = CoverTint.color(hue: hue, lightness: dark ? 0.3 : 0.9, chroma: dark ? 0.07 : 0.05)
  }
}
