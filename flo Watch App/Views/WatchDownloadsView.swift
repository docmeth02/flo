//
//  WatchDownloadsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchDownloadsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  var body: some View {
    List {
      if albumViewModel.downloadedAlbums.isEmpty {
        Text("No downloads yet")
          .customFont(.caption1)
          .foregroundColor(.secondary)
          .listRowBackground(Color.clear)
      } else {
        ForEach(albumViewModel.downloadedAlbums) { album in
          NavigationLink(destination: WatchAlbumDetailView(album: album)) {
            HStack(spacing: 8) {
              WatchAlbumArtView(
                url: albumViewModel.getAlbumCoverArt(
                  id: album.id, artistName: album.artist, albumName: album.name),
                size: 36
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
    }
    .navigationTitle("Downloads")
    .onAppear {
      albumViewModel.fetchDownloadedAlbums()
    }
  }
}
