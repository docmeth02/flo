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

  /// The parts that hold something and the room left, with their widths.
  private func widths(in width: CGFloat) -> [(color: Color, width: CGFloat)] {
    let shown = (parts + [Part(color: .floSurface2, bytes: usage.free)]).filter { $0.bytes > 0 }
    let widths = StorageUsage.barWidths(
      shown.map(\.bytes), in: width, gap: Self.gap, minimum: Self.height)
    return zip(shown, widths).map { ($0.color, $1) }
  }
}

extension View {
  /// Measures the storage when the view appears and again whenever
  /// `trigger` changes; only the newest measurement lands. A change waits a
  /// moment first, so a burst of finished songs walks the folders once.
  func measuresStorage(_ usage: Binding<StorageUsage>, trigger: some Equatable) -> some View {
    task(id: trigger) {
      if usage.wrappedValue != StorageUsage() {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
      }
      let measured = await StorageUsage.measure()
      if !Task.isCancelled { usage.wrappedValue = measured }
    }
  }
}
