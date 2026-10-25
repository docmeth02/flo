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
