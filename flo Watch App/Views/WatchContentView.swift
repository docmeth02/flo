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

  var body: some View {
    Group {
      if authViewModel.isLoggedIn {
        NavigationStack {
          WatchHomeView()
        }
      } else {
        WatchLoginView(viewModel: authViewModel)
      }
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
  }
}
