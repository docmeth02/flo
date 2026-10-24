//
//  RecentlyPlayedView.swift
//  Ownwave
//

import SwiftUI

/// Every album of Recently Played, from Home's See all.
struct RecentlyPlayedView: View {
  @EnvironmentObject private var albumViewModel: AlbumViewModel

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        PageTitle("Recently Played")
        if albumViewModel.recentAlbums.isEmpty {
          StateView(kind: .empty("Albums you play show up here."))
        } else {
          AlbumGrid(
            albums: albumViewModel.recentAlbums,
            downloaded: Set(albumViewModel.downloadedAlbums.map(\.id)))
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    .task {
      albumViewModel.fetchDownloadedAlbums()
      await albumViewModel.loadRecentAlbums()
    }
  }
}
