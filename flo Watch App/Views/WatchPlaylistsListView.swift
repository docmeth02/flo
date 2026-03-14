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
    .refreshable {
      await albumViewModel.refreshPlaylists()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshPlaylists() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
