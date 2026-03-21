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
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
    .environmentObject(downloadViewModel)
  }
}
