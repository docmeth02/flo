//
//  WatchQueueView.swift
//  flo Watch App
//

import SwiftUI

struct WatchQueueView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @Environment(\.setQueueShown) private var setQueueShown
  @State private var tint: Color?

  private var accent: Color { tint ?? .floLavender }
  // nowPlaying indexes the queue, which can be empty here.
  private var albumId: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.nowPlaying.albumId ?? "" : ""
  }
  private var coverURL: String { playerViewModel.coverArt }

  var body: some View {
    List {
      ForEach(Array(playerViewModel.queue.enumerated()), id: \.element.objectID) { index, item in
        TrackRowView(
          trackNumber: index + 1,
          title: item.songName ?? "Unknown",
          artist: item.artistName ?? "Unknown",
          isPlaying: index == playerViewModel.activeQueueIdx,
          tint: accent,
          idleBackground: .white.opacity(0.1)
        ) {
          playerViewModel.playFromQueue(idx: index)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      }
    }
    .containerBackground(for: .navigation) { CoverBackdrop(albumId: albumId, url: coverURL) }
    .task(id: albumId) { tint = await CoverTint.color(albumId: albumId, url: coverURL) }
    .navigationTitle("Queue")
    .onAppear { setQueueShown(true) }
    .onDisappear { setQueueShown(false) }
  }
}
