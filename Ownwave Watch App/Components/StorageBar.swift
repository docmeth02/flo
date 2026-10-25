//
//  StorageBar.swift
//  Ownwave Watch App
//

import SwiftUI

/// What music takes of the watch against the room left, as one bar:
/// Settings shows the cache and the downloads, Downloads its own part.
struct StorageBar: View {
  struct Part {
    let color: Color
    let bytes: Int64
  }

  let usage: StorageUsage
  let parts: [Part]

  private static let height: CGFloat = 5
  private static let gap: CGFloat = 2

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: Self.gap) {
        ForEach(Array(widths(in: proxy.size.width).enumerated()), id: \.offset) {
          Capsule().fill($0.element.color).frame(width: $0.element.width)
        }
      }
    }
    .frame(height: Self.height)
    .accessibilityHidden(true)
  }

  /// The parts that hold something and the room left, with their widths; a
  /// small part stays as wide as the bar is high, so it shows.
  private func widths(in width: CGFloat) -> [(color: Color, width: CGFloat)] {
    let shown = (parts + [Part(color: .floSurface2, bytes: usage.free)]).filter { $0.bytes > 0 }
    let room = width - Self.gap * CGFloat(max(shown.count - 1, 0))
    var widths = shown.map { max(Self.height, room * usage.share(of: $0.bytes)) }
    if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
      widths[widest] -= widths.reduce(0, +) - room
    }
    return zip(shown, widths).map { ($0.color, $1) }
  }
}

extension View {
  /// Measures the storage when the view appears and again whenever
  /// `trigger` changes; only the newest measurement lands.
  func measuresStorage(_ usage: Binding<StorageUsage>, trigger: some Equatable) -> some View {
    task(id: trigger) {
      let measured = await StorageUsage.measure()
      if !Task.isCancelled { usage.wrappedValue = measured }
    }
  }
}
