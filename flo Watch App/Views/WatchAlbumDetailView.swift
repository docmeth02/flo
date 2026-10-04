//
//  WatchAlbumDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloadViewModel: DownloadViewModel

  let album: Album

  @State private var localAlbum: Album?
  @State private var tint: Color = .floLavender

  private var displayAlbum: Album {
    localAlbum ?? album
  }

  private var meta: String {
    var parts = [album.albumArtist]
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let count = displayAlbum.songs.count
    if count > 0 { parts.append(counted(count, "song")) }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var body: some View {
    CollectionDetailView(
      collectionId: album.id,
      title: album.name,
      meta: meta,
      songs: displayAlbum.songs,
      tint: tint,
      trackNumber: { _, song in song.trackNumber },
      playable: { displayAlbum },
      onDownload: { downloadCollection() },
      onRemove: { albumViewModel.removeDownloadedAlbum(album: album) }
    ) {
      Spacer().frame(height: 58)
    }
    .background(alignment: .top) {
      CoverBackdrop(
        albumId: album.id, url: albumViewModel.getAlbumCoverArt(id: album.id), height: 220)
    }
    .task(id: album.id) {
      tint =
        await CoverTint.color(
          albumId: album.id, url: albumViewModel.getAlbumCoverArt(id: album.id)) ?? .floLavender
    }
    .onAppear { albumViewModel.setActiveAlbum(album: album) }
    .onReceive(albumViewModel.$album) { updated in
      if updated.id == album.id {
        localAlbum = updated
      }
    }
  }

  /// Downloaded playlists open here from Downloads; they keep playlist
  /// semantics (playlist folder, media ids) when missing tracks are fetched.
  private func downloadCollection() {
    if AlbumService.shared.isPlaylistDownload(id: album.id) {
      downloadViewModel.addItem(displayAlbum, isFromPlaylist: true)
    } else {
      albumViewModel.downloadAlbum(displayAlbum)
      downloadViewModel.addItem(displayAlbum)
    }
  }
}
