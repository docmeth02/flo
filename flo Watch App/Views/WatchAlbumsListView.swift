//
//  WatchAlbumsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    List {
      ForEach(albumViewModel.albums) { album in
        NavigationLink(destination: WatchAlbumDetailView(album: album)) {
          HStack(spacing: 8) {
            WatchAlbumArtView(
              url: albumViewModel.getAlbumCoverArt(id: album.id),
              size: 36,
              albumId: album.id
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
              Text(album.name)
                .customFont(.caption1)
                .lineLimit(1)

              Text(album.albumArtist)
                .customFont(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .navigationTitle("Albums")
    .refreshable {
      await albumViewModel.refreshAlbums()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshAlbums() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .onAppear {
      albumViewModel.fetchAlbums()
    }
  }
}
