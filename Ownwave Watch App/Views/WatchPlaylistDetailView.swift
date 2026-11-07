//
//  WatchPlaylistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession

  let playlist: Playlist

  @StateObject private var loader = CollectionSongs()

  /// The playlist with the songs shown, as the player and downloads take it.
  private var loadedPlaylist: Playlist {
    var loaded = playlist
    loaded.songs = loader.songs
    return loaded
  }

  /// "Playlist · 3 songs · 16 min", from the server's counts until the
  /// songs are loaded.
  private var meta: String {
    var length = loader.songs.countAndLength
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
      songs: loader.songs,
      trackNumber: { index, _ in index + 1 },
      playable: { Album(from: loadedPlaylist) },
      onDownload: { downloads.enqueue(loadedPlaylist) },
      onRemove: {
        albumViewModel.removeDownload(id: playlist.id, removed: loader.reload)
      }
    )
    .task(id: loader.reloads) { await loader.load { albumViewModel.loadSongs(of: playlist) } }
  }
}
