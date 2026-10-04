//
//  WatchQueueView.swift
//  flo Watch App
//

import SwiftUI

struct WatchQueueView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @Environment(\.setQueueShown) private var setQueueShown
  @State private var tint: Color?
  @State private var toast: FloToast.Message?

  private var accent: Color { tint ?? .floLavender }
  // nowPlaying indexes the queue, which can be empty here.
  private var albumId: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.nowPlaying.albumId ?? "" : ""
  }
  private var coverURL: String { playerViewModel.coverArt }
  /// The rows after the current one, with their index in the play order.
  private var upNext: [(offset: Int, element: QueueEntity)] {
    Array(playerViewModel.queue.enumerated().dropFirst(playerViewModel.activeQueueIdx + 1))
  }

  var body: some View {
    List {
      if playerViewModel.hasNowPlaying() {
        row(playerViewModel.nowPlaying, at: playerViewModel.activeQueueIdx)

        Section {
          ForEach(upNext, id: \.element.objectID) { index, item in
            row(item, at: index)
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                  remove(at: index)
                } label: {
                  Label("Remove", systemImage: "trash")
                }
              }
              .swipeActions(edge: .leading) {
                Button {
                  if playerViewModel.moveToNext(at: index) {
                    toast = FloToast.Message(text: "Playing next")
                  }
                } label: {
                  Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.floIndigo)
              }
          }

          if upNext.isEmpty {
            Text(
              UserDefaultsManager.keepPlaying
                ? "Nothing up next. Keep Playing will continue with Smart Shuffle."
                : "Nothing up next."
            )
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
          }
        } header: {
          FloSectionHeader("Up Next")
        }
      }
    }
    .floToast($toast)
    .containerBackground(for: .navigation) { CoverBackdrop(albumId: albumId, url: coverURL) }
    .task(id: albumId) { tint = await CoverTint.color(albumId: albumId, url: coverURL) }
    .navigationTitle("Queue")
    .onAppear { setQueueShown(true) }
    .onDisappear { setQueueShown(false) }
  }

  private func row(_ item: QueueEntity, at index: Int) -> some View {
    TrackRowView(
      trackNumber: index - playerViewModel.activeQueueIdx,
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

  private func remove(at index: Int) {
    guard let removed = playerViewModel.removeFromQueue(at: index) else { return }
    toast = FloToast.Message(text: "Removed \(removed.song.title)") {
      playerViewModel.undoRemove(removed)
    }
  }
}
