//
//  WatchAlbumDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchAlbumDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession

  let album: Album

  @StateObject private var loader = CollectionSongs()
  @State private var shades: CoverShades?

  /// The album with the tracks shown, as the player and downloads take it.
  private var loadedAlbum: Album {
    var loaded = album
    loaded.songs = loader.songs
    return loaded
  }

  private var meta: String {
    var parts = [album.albumArtist]
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let count = loader.songs.count
    if count > 0 { parts.append(counted(count, "song")) }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var body: some View {
    CollectionDetailView(
      collectionId: album.id,
      title: album.name,
      meta: meta,
      songs: loader.songs,
      tint: shades?.tint ?? Dusk.fill,
      // The design's dark shade of the cover's hue, at half strength.
      shade: shades?.background.opacity(0.5),
      blursCover: true,
      artist: album.albumArtist,
      trackNumber: { _, song in song.trackNumber },
      playable: { loadedAlbum },
      onDownload: { downloads.enqueue(loadedAlbum) },
      onRemove: {
        albumViewModel.removeDownload(id: album.id, removed: loader.reload)
      }
    )
    .coverShades($shades, albumId: album.id)
    .task(id: loader.reloads) { await loader.load { albumViewModel.loadSongs(of: album) } }
  }
}
