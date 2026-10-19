//
//  NowPlayingIndicator.swift
//  Ownwave Watch App
//

import SwiftUI

/// The home screen's hero for the playing song, drawn over its cover backdrop.
struct NowPlayingIndicator: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

  @State private var tint: Color = .floLilac

  var body: some View {
    // The home list drops this row when the queue empties, but this view can
    // refresh first (a logout clears the queue under it).
    if let song = playerViewModel.nowPlaying {
      content(song)
    }
  }

  private func content(_ song: QueueEntity) -> some View {
    VStack(spacing: 2) {
      Label("Now Playing", systemImage: playerViewModel.isPlaying ? "waveform" : "pause.fill")
        .labelStyle(NowPlayingLabelStyle())
        .font(.floCaption)
        .foregroundStyle(tint)

      Text(song.songName ?? "Unknown")
        .font(.floTitle)
        .lineLimit(1)

      Text(song.artistName ?? "Unknown")
        .font(.floMeta)
        .foregroundStyle(Color.floOnCover)
        .lineLimit(1)

      ProgressBar(clock: playerViewModel.clock, tint: tint)
        .padding(.top, 6)
    }
    .frame(maxWidth: .infinity)
    .multilineTextAlignment(.center)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .task(id: playerViewModel.nowPlayingAlbumId) {
      tint =
        await CoverTint.color(
          albumId: playerViewModel.nowPlayingAlbumId,
          url: playerViewModel.coverArt) ?? .floLilac
    }
  }

}

/// Observes the clock itself so the home screen does not redraw every second.
private struct ProgressBar: View {
  @ObservedObject var clock: PlayerClock
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width * 0.6
      Capsule()
        .fill(.white.opacity(0.22))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: width * clock.clampedProgress)
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
    }
    .frame(height: 3)
  }
}

private struct NowPlayingLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}
