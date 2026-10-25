//
//  TrackRowView.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// A song on its own surface platter, for scroll views. Inside a List, give
/// the row a clear background so the platter is not drawn twice. A tap runs
/// `action`, a hold `onHold` (the song menu). Without an artist the title
/// stands alone.
struct TrackRowView: View {
  private static let padding: CGFloat = 10
  private static let numberWidth: CGFloat = 18
  private static let spacing: CGFloat = 9
  /// Where the title starts, for hairlines between rows on one platter.
  static let textInset = padding + numberWidth + spacing

  let trackNumber: Int
  let title: String
  let artist: String
  var isPlaying: Bool = false
  var tint: Color = .floLilac
  /// Over a cover backdrop the opaque surface would hide the cover.
  var idleBackground: Color = .floSurface
  var onHold: (() -> Void)?
  var action: () -> Void

  var body: some View {
    HStack(spacing: Self.spacing) {
      Group {
        if isPlaying {
          Image(systemName: "waveform")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
        } else {
          Text("\(trackNumber)")
            .font(.counter)
            .foregroundStyle(Color.floSecondary)
        }
      }
      .frame(width: Self.numberWidth)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(.subheadline, weight: isPlaying ? .semibold : .medium))
          .foregroundStyle(isPlaying ? tint : .white)
          .lineLimit(1)
        if !artist.isEmpty {
          Text(artist)
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Self.padding)
    .padding(.vertical, 4)
    .frame(minHeight: FloLayout.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous)
        .fill(isPlaying ? tint.opacity(0.22) : idleBackground)
    )
    .holdable(onTap: action, onHold: onHold)
  }
}

extension View {
  /// Tap and hold on one plain view, which a `Button` cannot do on the watch:
  /// it takes the whole touch and the hold never arrives. The row dims while
  /// pressed, as a button would. Without `onHold` it is a plain tap target.
  func holdable(onTap: @escaping () -> Void, onHold: (() -> Void)?) -> some View {
    modifier(HoldableRow(onTap: onTap, onHold: onHold))
  }
}

struct HoldableRow: ViewModifier {
  let onTap: () -> Void
  let onHold: (() -> Void)?
  @State private var isPressed = false

  func body(content: Content) -> some View {
    content
      .opacity(isPressed ? FloLayout.pressedOpacity : 1)
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .onLongPressGesture(minimumDuration: FloLayout.holdDuration) {
        guard let onHold else { return }
        WKInterfaceDevice.current().play(.click)
        onHold()
      } onPressingChanged: {
        isPressed = $0
      }
  }
}
