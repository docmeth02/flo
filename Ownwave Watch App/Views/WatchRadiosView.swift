//
//  WatchRadiosView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchRadiosView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

  @StateObject var viewModel = RadiosViewModel()

  @Environment(\.showPlayer) private var showPlayer

  var body: some View {
    LibraryList(
      title: "Radios",
      state: viewModel.state,
      isEmpty: viewModel.radios.isEmpty,
      empty: .empty(
        systemImage: "dot.radiowaves.up.forward", tint: .floLilac, title: "No radios",
        message: "Add internet radio stations on your Navidrome server."),
      refresh: viewModel.refresh
    ) {
      ForEach(viewModel.radios, id: \.id) { radio in
        Button(action: {
          if playerViewModel.playRadioItem(radio: radio) { showPlayer() }
        }) {
          CoverRow(
            tile: .glyph("dot.radiowaves.up.forward", round: true), title: radio.name,
            subtitle: "")
        }
        .floRow()
      }
    }
    .onAppear {
      viewModel.fetchAllRadios()
    }
  }
}
