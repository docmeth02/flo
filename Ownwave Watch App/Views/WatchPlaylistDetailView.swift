//
//  WatchPlaylistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  let playlist: Playlist

  @StateObject private var loader = CollectionSongs()

  /// The playlist with the songs shown, as the player and downloads take it.
  private var loadedPlaylist: Playlist {
    var loaded = playlist
    loaded.songs = loader.songs
    return loaded
  }

  var body: some View {
    CollectionDetailView(
      collectionId: playlist.id,
      artId: playlist.artId,
      title: playlist.name,
      meta: playlist.meta(loaded: loader.songs),
      songs: loader.songs,
      trackNumber: { index, _ in index + 1 },
      playable: { Album(from: loadedPlaylist) },
      onDownload: { await CollectionDownload.startFromWatch(.playlist(loadedPlaylist)) },
      onRemove: {
        albumViewModel.removeDownload(id: playlist.id, removed: loader.reload)
      }
    )
    .task(id: loader.reloads) { await loader.load { albumViewModel.loadSongs(of: playlist) } }
  }
}
