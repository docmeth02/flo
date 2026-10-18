//
//  Artwork.swift
//  Ownwave
//

import SwiftUI

/// An album's cover from the download or the cover cache, decoded off the
/// main thread; a note glyph while it loads or when there is none.
struct CoverArt: View {
  let albumId: String
  /// A local path for a downloaded album, else empty.
  var url: String = ""
  var radius: CGFloat = 8

  @Environment(\.palette) private var palette
  // Remembered with the album it is for, so a reused view never shows the
  // previous album's cover.
  @State private var loaded: (albumId: String, image: UIImage?)?

  var body: some View {
    Color.clear
      .overlay {
        if let image = loaded?.albumId == albumId ? loaded?.image : nil {
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
      .task(id: albumId) {
        guard !albumId.isEmpty, loaded?.albumId != albumId else { return }
        let path = await CoverTint.coverFile(albumId: albumId, url: url)
        let decoded = await Task.detached(priority: .userInitiated) {
          path.flatMap(UIImage.init(contentsOfFile:)).flatMap(CoverTint.decoded)
        }.value
        guard !Task.isCancelled else { return }
        loaded = (albumId, decoded)
      }
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
