//
//  WatchArtistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  var body: some View {
    LibraryList(
      title: "Artists", state: albumViewModel.state(.artists),
      isEmpty: albumViewModel.artists.isEmpty,
      empty: .empty(
        systemImage: "music.mic", tint: .floLavender, title: "No artists",
        message: "Artists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshArtists
    ) {
      PinnedList(items: albumViewModel.artists, kind: .artist, allLabel: "All Artists") {
        artist, isPinned in
        ArtistRow(artist: artist, isPinned: isPinned, menu: $menu) { openedArtist = artist }
      }
    }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.getArtists()
    }
  }
}
