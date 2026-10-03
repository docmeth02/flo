//
//  WatchQueueView.swift
//  flo Watch App
//

import SwiftUI

struct WatchQueueView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @State private var tint: Color?

  private var accent: Color { tint ?? .floLavender }
  // nowPlaying indexes the queue, which can be empty here.
  private var albumId: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.nowPlaying.albumId ?? "" : ""
  }
  private var coverURL: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.getAlbumCoverArt() : ""
  }

  var body: some View {
    List {
      ForEach(Array(playerViewModel.queue.enumerated()), id: \.element.objectID) { index, item in
        let isCurrent = index == playerViewModel.activeQueueIdx
        Button(action: {
          playerViewModel.playFromQueue(idx: index)
        }) {
          HStack(spacing: 9) {
            Group {
              if isCurrent {
                Image(systemName: "waveform")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(accent)
              } else {
                Text("\(index + 1)")
                  .font(.system(size: 12, weight: .semibold).monospacedDigit())
                  .foregroundStyle(Color.floSecondary)
              }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
              Text(item.songName ?? "Unknown")
                .font(.floRowTitle)
                .foregroundStyle(isCurrent ? accent : .white)
              Text(item.artistName ?? "Unknown")
                .font(.floMeta)
                .foregroundStyle(Color.floSecondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)
          }
          .frame(minHeight: 46)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floRow(isCurrent ? accent.opacity(0.22) : .white.opacity(0.1))
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
      }
    }
    .containerBackground(for: .navigation) { CoverBackdrop(albumId: albumId, url: coverURL) }
    .task(id: albumId) { tint = await CoverTint.color(albumId: albumId, url: coverURL) }
    .navigationTitle("Queue")
  }
}
