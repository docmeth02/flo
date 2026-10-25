//
//  WatchAlbumDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchAlbumDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession

  let album: Album

  @State private var songs: [Song] = []
  @State private var isLoaded = false
  /// Bumped by a removed download, which loads the screen again.
  @State private var reloads = 0
  @State private var shades: CoverShades?

  /// The album with the tracks shown, as the player and downloads take it.
  private var loadedAlbum: Album {
    var loaded = album
    loaded.songs = songs
    return loaded
  }

  private var meta: String {
    var parts = [album.albumArtist]
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let count = songs.count
    if count > 0 { parts.append(counted(count, "song")) }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var body: some View {
    CollectionDetailView(
      collectionId: album.id,
      title: album.name,
      meta: meta,
      songs: songs,
      tint: shades?.tint ?? .floLilac,
      // The design's dark shade of the cover's hue, at half strength.
      shade: shades?.background.opacity(0.5),
      blursCover: true,
      artist: album.albumArtist,
      trackNumber: { _, song in song.trackNumber },
      playable: { loadedAlbum },
      onDownload: { downloads.enqueue(loadedAlbum) },
      onRemove: {
        albumViewModel.removeDownload(id: album.id) {
          isLoaded = false
          reloads += 1
        }
      }
    )
    .coverShades($shades, albumId: album.id)
    // Once: a return from a screen pushed on top keeps the loaded tracks,
    // also offline. A load cut short by that push or left empty runs again,
    // and so does one after a removed download.
    .task(id: reloads) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: album) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}
