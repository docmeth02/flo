//
//  WatchRadiosView.swift
//  flo Watch App
//

import SwiftUI

struct WatchRadiosView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @StateObject var viewModel = RadiosViewModel()

  @State private var showNowPlaying = false

  var body: some View {
    List {
      if viewModel.radios.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: 28))
            .foregroundColor(.secondary)
          Text("No radios available")
            .customFont(.caption1)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
      } else {
        ForEach(viewModel.radios, id: \.id) { radio in
          Button(action: {
            playerViewModel.playRadioItem(radio: radio)
            showNowPlaying = true
          }) {
            HStack(spacing: 10) {
              Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

              Text(radio.name)
                .customFont(.caption1)
                .lineLimit(2)
            }
          }
        }
      }
    }
    .navigationTitle("Radios")
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .onAppear {
      viewModel.fetchAllRadios()
    }
  }
}
