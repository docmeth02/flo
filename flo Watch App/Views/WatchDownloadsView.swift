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
              HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                  .font(.system(size: 16))
                  .foregroundStyle(Color.floLavender)
                  .frame(width: 36, height: 36)
                  .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .fill(Color.floLavender.opacity(0.18)))

                VStack(alignment: .leading, spacing: 1) {
                  Text("Cached")
                    .font(.floRowTitle)
                    .lineLimit(1)

                  Text("\(cachedSongs.count) songs")
                    .font(.floMeta)
                    .foregroundStyle(Color.floSecondary)
                    .lineLimit(1)
                }
              }
              .frame(minHeight: 52)
            }
            .floRow()
          }

          ForEach(albumViewModel.downloadedAlbums) { album in
            NavigationLink(destination: WatchAlbumDetailView(album: album)) {
              CoverRow(
                coverURL: albumViewModel.getAlbumCoverArt(
                  id: album.id, artistName: album.artist, albumName: album.name),
                albumId: album.id,
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
