//
//  WatchDownloadsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchDownloadsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @State private var cachedSongs: [Song] = []

  var body: some View {
    Group {
      if albumViewModel.downloadedAlbums.isEmpty && cachedSongs.isEmpty {
        LibraryPlaceholder(
          kind: .empty(
            systemImage: "arrow.down.circle", tint: .floLavender, title: "No downloads yet",
            message: "Download an album or playlist to play it without a connection."))
      } else {
        List {
          // Cached songs section
          if !cachedSongs.isEmpty {
            NavigationLink(destination: WatchCachedSongsView(songs: cachedSongs)) {
              CoverRow(
                tile: .glyph("music.note.list"), title: "Cached",
                subtitle: "\(cachedSongs.count) song\(cachedSongs.count == 1 ? "" : "s")")
            }
            .floRow()
          }

          ForEach(albumViewModel.downloadedAlbums) { album in
            NavigationLink(destination: WatchAlbumDetailView(album: album)) {
              CoverRow(
                tile: .cover(
                  url: albumViewModel.getAlbumCoverArt(
                    id: album.id, artistName: album.artist, albumName: album.name),
                  albumId: album.id),
                title: album.name,
                subtitle: album.albumArtist
              ) {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 16))
                  .foregroundStyle(Color.floDownloaded)
              }
            }
            .floRow()
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
