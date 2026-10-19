//
//  WatchPlaylistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession

  let playlist: Playlist

  @State private var songs: [Song] = []
  @State private var isLoaded = false
  /// Bumped by a removed download, which loads the screen again.
  @State private var reloads = 0

  /// The playlist with the songs shown, as the player and downloads take it.
  private var loadedPlaylist: Playlist {
    var loaded = playlist
    loaded.songs = songs
    return loaded
  }

  private var meta: String {
    if !playlist.comment.isEmpty { return playlist.comment }
    let count = songs.count
    return count > 0 ? counted(count, "song") : ""
  }

  var body: some View {
    CollectionDetailView(
      collectionId: playlist.id,
      title: playlist.name,
      meta: meta,
      songs: songs,
      trackNumber: { index, _ in index + 1 },
      playable: { Album(from: loadedPlaylist) },
      onDownload: { downloads.enqueue(loadedPlaylist) },
      onRemove: {
        albumViewModel.removeDownload(id: playlist.id) {
          isLoaded = false
          reloads += 1
        }
      }
    ) {
      Image(systemName: "music.note.list")
        .font(.system(size: 34))
        .foregroundStyle(Color.floLilac)
        .frame(width: 80, height: 80)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.floSurface)
        )
        .padding(.bottom, 6)
    }
    // Once, as an album.
    .task(id: reloads) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: playlist) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}
