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
  @State private var tint: Color = .floLilac

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
      tint: tint,
      onCover: true,
      trackNumber: { _, song in song.trackNumber },
      playable: { loadedAlbum },
      onDownload: { downloads.enqueue(loadedAlbum) },
      onRemove: { albumViewModel.removeDownload(id: album.id) { isLoaded = false } }
    ) {
      Spacer().frame(height: 58)
    }
    .background(alignment: .top) { CoverBackdrop(albumId: album.id, height: 220) }
    .task(id: album.id) { tint = await CoverTint.color(albumId: album.id) ?? .floLilac }
    // Once: a return from a screen pushed on top keeps the loaded tracks,
    // also offline. A load cut short by that push or left empty runs again,
    // and so does one after a removed download.
    .task(id: isLoaded) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: album) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}
