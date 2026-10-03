//
//  WatchPlaylistDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloadViewModel: DownloadViewModel

  let playlist: Playlist

  private var displayPlaylist: Playlist {
    albumViewModel.playlist.id == playlist.id ? albumViewModel.playlist : playlist
  }

  private var meta: String {
    if !playlist.comment.isEmpty { return playlist.comment }
    let count = displayPlaylist.songs.count
    return count > 0 ? "\(count) song\(count == 1 ? "" : "s")" : ""
  }

  private func downloadPlaylist() {
    let playablePlaylist = Album(from: displayPlaylist)
    albumViewModel.downloadPlaylist(displayPlaylist)
    downloadViewModel.addItem(playablePlaylist, isFromPlaylist: true)
  }

  var body: some View {
    CollectionDetailView(
      collectionId: playlist.id,
      title: playlist.name,
      meta: meta,
      songs: displayPlaylist.songs,
      trackNumber: { index, _ in index + 1 },
      playable: { Album(from: displayPlaylist) },
      onDownload: { downloadPlaylist() },
      onRemove: { albumViewModel.removeDownloadedPlaylist(playlist: playlist) }
    ) {
      Image(systemName: "music.note.list")
        .font(.system(size: 34))
        .foregroundStyle(Color.floLavender)
        .frame(width: 80, height: 80)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.floLavender.opacity(0.18))
        )
        .padding(.bottom, 6)
    }
    .onAppear { albumViewModel.setActivePlaylist(playlist: playlist) }
  }
}
