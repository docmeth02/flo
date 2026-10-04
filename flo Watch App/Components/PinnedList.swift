//
//  PinnedList.swift
//  flo Watch App
//

import SwiftUI

/// List sections for a library list with pins: the pinned items on top,
/// then a hairline, the `allLabel` and every item, the pinned ones again in
/// their place. Without pins only the full list shows.
struct PinnedList<Item: Identifiable, Row: View>: View where Item.ID == String {
  let items: [Item]
  let kind: PinStore.Kind
  let allLabel: String
  @ViewBuilder let row: (Item, _ isPinned: Bool) -> Row

  var body: some View {
    EmptyView()
  }
}
