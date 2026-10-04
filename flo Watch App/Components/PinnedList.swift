//
//  PinnedList.swift
//  flo Watch App
//

import SwiftUI

/// List sections for a library list with pins: the pinned items on top,
/// then a hairline, the `allLabel` and every item, the pinned ones again in
/// their place. Without pins only the full list shows.
struct PinnedList<Item: Identifiable, Row: View>: View where Item.ID == String {
  @EnvironmentObject private var pinStore: PinStore

  let items: [Item]
  let kind: PinStore.Kind
  let allLabel: String
  @ViewBuilder let row: (Item, _ isPinned: Bool) -> Row

  var body: some View {
    let pinned = pinStore.pinned(kind)
    if pinned.isEmpty {
      rows(items, pinned)
    } else {
      Section {
        rows(items.filter { pinned.contains($0.id) }, pinned)
      }
      Section {
        rows(items, pinned)
      } header: {
        VStack(alignment: .leading, spacing: 6) {
          Rectangle().fill(Color.floHairline).frame(height: 1)
          FloSectionHeader(allLabel)
        }
      }
    }
  }

  private func rows(_ items: [Item], _ pinned: Set<String>) -> some View {
    ForEach(items) { row($0, pinned.contains($0.id)) }
  }
}

/// The trailing mark of a pinned row.
struct PinGlyph: View {
  var body: some View {
    Image(systemName: "pin.fill")
      .font(.system(size: 13))
      .foregroundStyle(Color.floLavender)
  }
}
