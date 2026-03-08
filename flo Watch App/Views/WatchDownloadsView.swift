//
//  WatchDownloadsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchDownloadsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @State private var cachedSongs: [Song] = []

  var body: some View {
    List {
      if albumViewModel.downloadedAlbums.isEmpty && cachedSongs.isEmpty {
        Text("No downloads yet")
          .customFont(.caption1)
          .foregroundColor(.secondary)
          .listRowBackground(Color.clear)
      } else {
        // Cached songs section
        if !cachedSongs.isEmpty {
          NavigationLink(destination: WatchCachedSongsView(songs: cachedSongs)) {
            HStack(spacing: 8) {
              Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)

              VStack(alignment: .leading, spacing: 2) {
                Text("Cached")
                  .customFont(.caption1)
                  .lineLimit(1)

                Text("\(cachedSongs.count) songs")
                  .customFont(.caption2)
                  .foregroundColor(.secondary)
                  .lineLimit(1)
              }
            }
          }
        }

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
      cachedSongs = StreamCacheManager.shared.getCachedSongs()
    }
  }
}
