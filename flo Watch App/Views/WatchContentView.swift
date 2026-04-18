//
//  WatchContentView.swift
//  flo Watch App
//

import SwiftUI

struct WatchContentView: View {
  @StateObject private var authViewModel = AuthViewModel()
  @StateObject private var playerViewModel = WatchPlayerViewModel()
  @StateObject private var albumViewModel = AlbumViewModel()
  @StateObject private var floooViewModel = FloooViewModel()
  @StateObject private var downloadViewModel = DownloadViewModel()
  @ObservedObject private var connectivity = ConnectivityMonitor.shared

  var body: some View {
    Group {
      if authViewModel.isLoggedIn {
        NavigationStack {
          TabView {
            WatchHomeView()

            if playerViewModel.hasNowPlaying() {
              WatchNowPlayingView()
            }
          }
          .tabViewStyle(.page)
        }
      } else {
        WatchLoginView(viewModel: authViewModel)
      }
    }
    .overlay(alignment: .top) {
      if !connectivity.isOnline {
        HStack(spacing: 4) {
          Image(systemName: "wifi.slash")
          Text("Offline")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary))
        .padding(.top, 2)
        .transition(.opacity)
      }
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
    .environmentObject(downloadViewModel)
  }
}
