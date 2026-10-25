//
//  WatchPlaylistsListView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchPlaylistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @State private var openedPlaylist: Playlist?
  @State private var menu: MenuTarget?

  var body: some View {
    let playlists = albumViewModel.playlists
    LibraryList(
      title: "Playlists", state: albumViewModel.state(.playlists),
      isEmpty: playlists.isEmpty,
      empty: .empty(
        systemImage: "music.note.list", tint: .floLilac, title: "No playlists",
        message: "Playlists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshPlaylists
    ) {
      PinnedList(items: playlists, kind: .playlist, allLabel: "All Playlists") { playlists, _ in
        JoinedRows(items: playlists) { playlist in
          LibraryRow(target: .playlist(playlist), showsChevron: true, menu: $menu) {
            openedPlaylist = playlist
          }
        }
      }
      if playlists.count < LibraryHint.shortList {
        LibraryHint("Playlists you make in Navidrome show up here.")
      }
    }
    .navigationDestination(item: $openedPlaylist) { WatchPlaylistDetailView(playlist: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
