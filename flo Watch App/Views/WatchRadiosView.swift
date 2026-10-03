//
//  WatchRadiosView.swift
//  flo Watch App
//

import SwiftUI

struct WatchRadiosView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @StateObject var viewModel = RadiosViewModel()

  @Environment(\.showPlayer) private var showPlayer

  private var placeholder: StateView.Kind {
    if viewModel.error != nil {
      return .error(retry: { viewModel.fetchAllRadios() })
    }
    return .empty(
      systemImage: "dot.radiowaves.up.forward", tint: .floLavender, title: "No radios",
      message: "Add internet radio stations on your Navidrome server.")
  }

  var body: some View {
    Group {
      if viewModel.radios.isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List {
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
      }
    }
    .navigationTitle("Radios")
    .onAppear {
      viewModel.fetchAllRadios()
    }
  }
}
