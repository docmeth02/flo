//
//  WatchPlaylistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    LibraryList(
      title: "Playlists", state: albumViewModel.state(.playlists),
      isEmpty: albumViewModel.playlists.isEmpty,
      empty: .empty(
        systemImage: "music.note.list", tint: .floLavender, title: "No playlists",
        message: "Playlists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshPlaylists
    ) {
      ForEach(albumViewModel.playlists) { playlist in
        NavigationLink(destination: WatchPlaylistDetailView(playlist: playlist)) {
          CoverRow(tile: .glyph("music.note.list"), title: playlist.name, subtitle: playlist.comment)
        }
        .floRow()
      }
    }
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
