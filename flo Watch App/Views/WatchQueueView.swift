//
//  WatchQueueView.swift
//  flo Watch App
//

import SwiftUI

struct WatchQueueView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  var body: some View {
    List {
      ForEach(Array(playerViewModel.queue.enumerated()), id: \.offset) { index, item in
        Button(action: {
          playerViewModel.playFromQueue(idx: index)
        }) {
          HStack(spacing: 8) {
            if index == playerViewModel.activeQueueIdx {
              Image(systemName: "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            } else {
              Text("\(index + 1)")
                .customFont(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(item.songName ?? "Unknown")
                .customFont(.caption1)
                .lineLimit(1)
                .foregroundColor(
                  index == playerViewModel.activeQueueIdx ? .accentColor : .primary)

              Text(item.artistName ?? "Unknown")
                .customFont(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .navigationTitle("Queue")
  }
}
