//
//  WatchQueueView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchQueueView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel
  // Redraws the reasons when a played mix lands.
  @ObservedObject private var mixes = RecommendationLog.shared
  @Environment(\.setQueueShown) private var setQueueShown
  @State private var shades: CoverShades?
  @State private var toast: FloToast.Message?

  private var albumId: String {
    playerViewModel.nowPlayingAlbumId
  }
  private var coverURL: String { playerViewModel.coverArt }
  /// The rows after the current one, in play order.
  private var upNext: [QueueEntity] {
    Array(playerViewModel.queue.dropFirst(playerViewModel.activeQueueIdx + 1))
  }

  var body: some View {
    List {
      if let song = playerViewModel.nowPlaying {
        current(song)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

        let upNext = upNext
        Section {
          ForEach(Array(upNext.enumerated()), id: \.element.objectID) { index, item in
            row(item)
              .floJoinedRow(RowPosition(index: index, count: upNext.count))
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                  remove(item)
                } label: {
                  Label("Remove", systemImage: "trash")
                }
              }
              .swipeActions(edge: .leading) {
                Button {
                  if let index = position(of: item), playerViewModel.moveToNext(at: index) {
                    toast = FloToast.Message(text: "Playing next")
                  }
                } label: {
                  Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.floLilacDeep)
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
          CapsLabel(upNext.isEmpty ? "Next" : "Next · " + counted(upNext.count, "song"))
        }
      }
    }
    // Joined rows: the default style shrinks the rows at the screen's edges
    // and splits their platter.
    .listStyle(.plain)
    // As low as their content; at 0 watchOS skips a section's edge rows.
    .environment(\.defaultMinListRowHeight, 1)
    .floToast($toast)
    .containerBackground(for: .navigation) { CoverBackdrop(albumId: albumId, url: coverURL) }
    .coverShades($shades, albumId: albumId, url: coverURL)
    .floNavigationTitle("Up Next")
    .onAppear { setQueueShown(true) }
    .onDisappear { setQueueShown(false) }
  }

  /// The playing song on its cover's shade, with the time it has left.
  private func current(_ song: QueueEntity) -> some View {
    let tint = shades?.tint ?? .floLilac
    return HStack(spacing: FloLayout.tileSpacing) {
      Image(systemName: playerViewModel.isPlaying ? "waveform" : "pause.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(song.songName ?? "Unknown")
          .font(.floSong)
          .foregroundStyle(tint)
        Text(song.artistName ?? "Unknown")
          .font(.floMeta)
          .foregroundStyle(Color.floSecondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      if !playerViewModel.isLiveRadio {
        Remaining(clock: playerViewModel.clock, duration: song.duration)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: FloLayout.platterRadius, style: .continuous)
        .fill(shades?.background ?? .floSurface2)
    )
    .holdable(
      onTap: { playerViewModel.playFromQueue(idx: playerViewModel.activeQueueIdx) }, onHold: nil)
  }

  private func row(_ item: QueueEntity) -> some View {
    HStack(spacing: FloLayout.tileSpacing) {
      WatchAlbumArtView(albumId: item.albumId ?? "", size: FloLayout.smallThumbnail)
        .clipShape(RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.songName ?? "Unknown")
          .font(.floRowTitle)
        subtitle(item)
          .font(.floMeta)
          .foregroundStyle(Color.floSecondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(minHeight: FloLayout.smallThumbnail + FloLayout.coverRowHeight - FloLayout.thumbnail)
    .holdable(
      onTap: {
        if let index = position(of: item) { playerViewModel.playFromQueue(idx: index) }
      }, onHold: nil)
  }

  /// "Artist · ✦ Fits": why a mix picked the song, while that is shown.
  private func subtitle(_ item: QueueEntity) -> Text {
    let artist = item.artistName ?? "Unknown"
    guard let why = mixes.shownReason(for: item) else { return Text(artist) }
    let icon = Text(Image(systemName: why.kind.systemImage))
      .foregroundStyle(why.kind.color(.dark))
    return Text("\(artist) · \(icon) \(why.label)")
  }

  /// Where the entry is now: an edit or a song change since the row was
  /// drawn moves it.
  private func position(of item: QueueEntity) -> Int? {
    playerViewModel.queue.firstIndex { $0.objectID == item.objectID }
  }

  private func remove(_ item: QueueEntity) {
    guard let index = position(of: item),
      let removed = playerViewModel.removeFromQueue(at: index)
    else { return }
    toast = FloToast.Message(text: "Removed \(removed.song.title)") {
      playerViewModel.undoRemove(removed)
    }
  }
}

/// "-3:02"; observes the clock itself so the queue does not redraw every
/// second.
private struct Remaining: View {
  @ObservedObject var clock: PlayerClock
  let duration: Double

  var body: some View {
    Text("-" + (duration * (1 - clock.clampedProgress)).minuteSecond)
      .font(.floTime)
      .foregroundStyle(Color.floSecondary)
  }
}
