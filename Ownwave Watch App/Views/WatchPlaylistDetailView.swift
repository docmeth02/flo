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

  /// "Playlist · 3 songs · 16 min", from the server's counts until the
  /// songs are loaded.
  private var meta: String {
    var length = songs.countAndLength
    if length.isEmpty, playlist.songCount > 0 {
      length = songsAndLength(playlist.songCount, seconds: playlist.duration)
    }
    return length.isEmpty ? "Playlist" : "Playlist · " + length
  }

  var body: some View {
    CollectionDetailView(
      collectionId: playlist.id,
      artId: playlist.artId,
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
    )
    // Once, as an album.
    .task(id: reloads) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: playlist) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}
