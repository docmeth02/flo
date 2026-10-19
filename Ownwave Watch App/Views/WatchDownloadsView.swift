//
//  WatchDownloadsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchDownloadsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession
  @ObservedObject private var phone = PhoneLink.shared

  @State private var cachedSongs: [Song] = []

  var body: some View {
    Group {
      if albumViewModel.downloadedAlbums.isEmpty && cachedSongs.isEmpty {
        LibraryPlaceholder(
          kind: .empty(
            systemImage: "arrow.down.circle", tint: .floLilac, title: "No downloads yet",
            message: "Download an album or playlist to play it without a connection."))
      } else {
        List {
          // Cached songs section
          if !cachedSongs.isEmpty {
            NavigationLink(destination: WatchCachedSongsView(songs: cachedSongs)) {
              CoverRow(
                tile: .glyph("music.note.list"), title: "Cached",
                subtitle: counted(cachedSongs.count, "song"))
            }
            .floRow()
          }

          ForEach(albumViewModel.downloadedAlbums) { album in
            NavigationLink(destination: WatchAlbumDetailView(album: album)) {
              CoverRow(tile: .album(album.id), title: album.name, subtitle: album.albumArtist) {
                // An album shows up here with its first song, so the check
                // waits until its download has finished without a failure.
                if downloads.isDownloading(collectionId: album.id) {
                  Text("\(Int(downloads.progress(collectionId: album.id) * 100))%")
                    .font(.system(.footnote, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.floLilac)
                } else if phone.isReceiving(collectionId: album.id) {
                  Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.floLilac)
                } else if downloads.hasFailed(collectionId: album.id) {
                  Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.floDestructive)
                } else {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.floDownloaded)
                }
              }
            }
            .floRow()
          }
        }
      }
    }
    .floNavigationTitle("Downloads")
    .onAppear {
      albumViewModel.fetchDownloadedAlbums()
      cachedSongs = StreamCacheManager.shared.getCachedSongs()
    }
    // An album being downloaded shows up here with its first song.
    .onReceive(downloads.downloadFinished) { id in
      if !albumViewModel.downloadedAlbums.contains(where: { $0.id == id }) {
        albumViewModel.fetchDownloadedAlbums()
      }
    }
  }
}
