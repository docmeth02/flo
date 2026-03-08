//
//  NowPlayingIndicator.swift
//  flo Watch App
//

import SwiftUI

struct NowPlayingIndicator: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  var body: some View {
    HStack(spacing: 8) {
      // Small album art
      WatchAlbumArtView(
        url: playerViewModel.getAlbumCoverArt(),
        size: 36,
        albumId: playerViewModel.nowPlaying.albumId ?? ""
      )
      .clipShape(RoundedRectangle(cornerRadius: 4))

      VStack(alignment: .leading, spacing: 2) {
        Text(playerViewModel.nowPlaying.songName ?? "Unknown")
          .customFont(.caption1)
          .fontWeight(.semibold)
          .lineLimit(1)

        Text(playerViewModel.nowPlaying.artistName ?? "Unknown")
          .customFont(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Image(systemName: playerViewModel.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
        .font(.caption2)
        .foregroundColor(.accentColor)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}
