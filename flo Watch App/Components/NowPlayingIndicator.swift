//
//  NowPlayingIndicator.swift
//  flo Watch App
//

import SwiftUI

/// The home screen's hero for the playing song, drawn over its cover backdrop.
struct NowPlayingIndicator: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @State private var tint: Color = .floLavender

  var body: some View {
    // The home list drops this row when the queue empties, but this view can
    // refresh first (a logout clears the queue under it).
    if playerViewModel.hasNowPlaying() {
      content
    }
  }

  private var content: some View {
    VStack(spacing: 2) {
      Label("Now Playing", systemImage: playerViewModel.isPlaying ? "waveform" : "pause.fill")
        .labelStyle(NowPlayingLabelStyle())
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)

      Text(playerViewModel.nowPlaying.songName ?? "Unknown")
        .font(.custom("Plus Jakarta Sans", size: 16, relativeTo: .headline).weight(.bold))
        .lineLimit(1)

      Text(playerViewModel.nowPlaying.artistName ?? "Unknown")
        .font(.floMeta)
        .foregroundStyle(Color.floOnCover)
        .lineLimit(1)

      progressBar
        .padding(.top, 6)
    }
    .frame(maxWidth: .infinity)
    .multilineTextAlignment(.center)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .task(id: playerViewModel.nowPlaying.albumId) {
      tint = await CoverTint.color(albumId: playerViewModel.nowPlaying.albumId ?? "") ?? .floLavender
    }
  }

  private var progressBar: some View {
    GeometryReader { geometry in
      let width = geometry.size.width * 0.6
      Capsule()
        .fill(.white.opacity(0.22))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: width * min(max(playerViewModel.progress, 0), 1))
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
