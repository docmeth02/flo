//
//  FloToast.swift
//  Ownwave Watch App
//

import SwiftUI

/// A short message over the bottom of a screen, with Undo when the change
/// can be taken back. It clears `message` itself after `duration`.
struct FloToast: View {
  struct Message: Equatable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)?

    static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
  }

  static let duration: Duration = .seconds(2.6)

  @Binding var message: Message?

  var body: some View {
    if let current = message {
      HStack(spacing: 6) {
        Text(current.text)
          .font(.floMeta.weight(.medium))
          .lineLimit(1)
        if let undo = current.undo {
          Button("Undo") {
            undo()
            message = nil
          }
          .font(.floMeta.weight(.semibold))
          .foregroundStyle(Color.floLilac)
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Capsule().fill(Color.floSurface))
      .shadow(color: .black.opacity(0.6), radius: 9, y: 6)
      .task(id: current.id) {
        try? await Task.sleep(for: Self.duration)
        if message?.id == current.id { message = nil }
      }
    }
  }
}

extension View {
  /// Shows `message` as a `FloToast` over the bottom of this view.
  func floToast(_ message: Binding<FloToast.Message?>) -> some View {
    overlay(alignment: .bottom) { FloToast(message: message).padding(.bottom, 4) }
  }
}
