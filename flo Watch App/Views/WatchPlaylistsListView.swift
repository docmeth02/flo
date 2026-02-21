//
//  WatchPlaylistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    List {
      ForEach(albumViewModel.playlists) { playlist in
        NavigationLink(destination: WatchPlaylistDetailView(playlist: playlist)) {
          VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
              .customFont(.caption1)
              .lineLimit(1)

            if !playlist.comment.isEmpty {
              Text(playlist.comment)
                .customFont(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .navigationTitle("Playlists")
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
