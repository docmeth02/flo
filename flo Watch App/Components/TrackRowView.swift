//
//  TrackRowView.swift
//  flo Watch App
//

import SwiftUI

struct TrackRowView: View {
  let trackNumber: Int
  let title: String
  let artist: String
  var isPlaying: Bool = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isPlaying {
          Image(systemName: "speaker.wave.2.fill")
            .font(.caption2)
            .foregroundColor(.accentColor)
            .frame(width: 20)
        } else {
          Text("\(trackNumber)")
            .customFont(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 20)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .customFont(.caption1)
            .lineLimit(1)
            .foregroundColor(isPlaying ? .accentColor : .primary)

          Text(artist)
            .customFont(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
  }
}
