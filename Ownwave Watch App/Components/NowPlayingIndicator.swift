//
//  NowPlayingIndicator.swift
//  Ownwave Watch App
//

import SwiftUI

/// The top of Home's card: the playing song on its cover's shade.
struct NowPlayingIndicator: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

  @State private var shades: CoverShades?

  var body: some View {
    // The home list drops this row when the queue empties, but this view can
    // refresh first (a logout clears the queue under it).
    if let song = playerViewModel.nowPlaying {
      content(song)
    }
  }

  private func content(_ song: QueueEntity) -> some View {
    let tint = shades?.tint ?? .floLilac
    return VStack(spacing: 8) {
      HStack(spacing: FloLayout.tileSpacing) {
        WatchAlbumArtView(albumId: playerViewModel.nowPlayingAlbumId)
          .clipShape(RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          CapsLabel(playerViewModel.isPlaying ? "Now Playing" : "Paused", tint: tint)
          Text(song.songName ?? "Unknown")
            .font(.floSong)
          Text(song.artistName ?? "Unknown")
            .font(.floMeta)
            .foregroundStyle(tint)
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      ProgressBar(clock: playerViewModel.clock, tint: tint)
    }
    .padding(10)
    .background(shades?.background ?? .floSurface2)
    .coverShades($shades, albumId: playerViewModel.nowPlayingAlbumId, url: playerViewModel.coverArt)
  }
}

/// A cover's two dark shades, as on the phone: the tint for text and the
/// backdrop of a tinted card. Nil until the cover is read, and for a gray one.
struct CoverShades {
  let tint: Color
  let background: Color

  init(hue: Double) {
    tint = CoverTint.color(hue: hue, lightness: 0.86, chroma: 0.1)
    background = CoverTint.color(hue: hue, lightness: 0.3, chroma: 0.07)
  }
}

extension View {
  /// Keeps `shades` at the colors of the album's cover.
  func coverShades(_ shades: Binding<CoverShades?>, albumId: String, url: String = "") -> some View
  {
    task(id: albumId) {
      shades.wrappedValue = await CoverTint.hue(albumId: albumId, url: url).map(CoverShades.init)
    }
  }
}

/// Observes the clock itself so the home screen does not redraw every second.
private struct ProgressBar: View {
  @ObservedObject var clock: PlayerClock
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      Capsule()
        .fill(.white.opacity(0.14))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: geometry.size.width * clock.clampedProgress)
        }
    }
    .frame(height: 3)
  }
}
