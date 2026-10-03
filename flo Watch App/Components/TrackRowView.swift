//
//  TrackRowView.swift
//  flo Watch App
//

import SwiftUI

/// A song on its own surface platter, for scroll views. Inside a List, give
/// the row a clear background so the platter is not drawn twice.
struct TrackRowView: View {
  let trackNumber: Int
  let title: String
  let artist: String
  var isPlaying: Bool = false
  var tint: Color = .floLavender
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Group {
          if isPlaying {
            Image(systemName: "waveform")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(tint)
          } else {
            Text("\(trackNumber)")
              .font(.system(.caption, weight: .semibold).monospacedDigit())
              .foregroundStyle(Color.floSecondary)
          }
        }
        .frame(width: 18)

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(.subheadline, weight: isPlaying ? .semibold : .medium))
            .foregroundStyle(isPlaying ? tint : .white)
            .lineLimit(1)
          Text(artist)
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .frame(minHeight: 44)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isPlaying ? tint.opacity(0.22) : Color.floSurface)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
