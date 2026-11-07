//
//  WatchRadiosView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchRadiosView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

  @StateObject var viewModel = RadiosViewModel()

  @Environment(\.showPlayer) private var showPlayer
  @State private var menu: MenuTarget?

  var body: some View {
    let radios = viewModel.radios
    LibraryList(
      title: "Radios",
      state: viewModel.state,
      isEmpty: radios.isEmpty,
      empty: .empty(
        systemImage: Glyph.radio, tint: Dusk.fill, title: "No radios",
        message: "Add internet radio stations on your Navidrome server."),
      refresh: viewModel.refresh
    ) {
      PinnedList(items: radios, kind: .radio, allLabel: "All Radios") { radios, _ in
        JoinedRows(items: radios) { radio in
          RadioRow(radio: radio)
            .holdable(
              onTap: { if playerViewModel.playRadioItem(radio: radio) { showPlayer() } },
              onHold: { menu = .radio(radio) })
        }
      }
      if radios.count < LibraryHint.shortList {
        LibraryHint("Stations you add in Navidrome show up here.")
      }
    }
    .itemMenu($menu)
    .onAppear {
      viewModel.fetchAllRadios()
    }
  }
}

/// A station: its glyph, the name, "Live stream" behind a red dot, and the
/// pin of a pinned one.
private struct RadioRow: View {
  @EnvironmentObject private var pinStore: PinStore

  let radio: Radio

  var body: some View {
    HStack(spacing: WatchLayout.tileSpacing) {
      CoverTile.radio.view(size: WatchLayout.smallThumbnail)
      VStack(alignment: .leading, spacing: 1) {
        Text(radio.name)
          .font(.rowTitle)
          .lineLimit(2)
        HStack(spacing: 4) {
          StatusDot(color: .liked)
          Text("Live stream")
            .font(.meta)
            .foregroundStyle(Dusk.secondary)
        }
      }
      Spacer(minLength: 0)
      if pinStore.isPinned(radio.id, .radio) {
        PinGlyph()
      }
    }
    .frame(minHeight: WatchLayout.joinedRowHeight)
    .accessibilityElement(children: .combine)
  }
}
