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
              HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.up.forward")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.floLavender)
                  .frame(width: 30, height: 30)
                  .background(Circle().fill(Color.floLavender.opacity(0.18)))

                Text(radio.name)
                  .font(.floRow)
                  .lineLimit(2)
              }
              .frame(minHeight: 44)
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
