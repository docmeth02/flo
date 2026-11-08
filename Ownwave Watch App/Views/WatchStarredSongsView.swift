//
//  WatchStarredSongsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  // Redraws the lists when an item is unliked.
  @ObservedObject private var starStore = StarStore.shared

  @Environment(\.showPlayer) private var showPlayer
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  /// Unliked songs leave at once, before the list reloads.
  private var songs: [Song] { albumViewModel.likedSongs(playerViewModel) }

  var body: some View {
    let songs = songs
    LibraryList(
      title: "Liked Songs", state: albumViewModel.state(.starredSongs),
      isEmpty: songs.isEmpty,
      empty: .empty(
        systemImage: "heart.fill", tint: .liked, title: "No liked songs yet",
        message: "Tap the heart on Now Playing to add a song here."),
      refresh: albumViewModel.refreshStarredSongs
    ) {
      SongRows(
        songs: songs,
        onHold: { menu = .song($0, context: SongCollection.Name.liked, isFromPlaylist: false) }
      ) {
        if playerViewModel.playItem(item: SongCollection.liked(songs), startingAt: $0) {
          showPlayer()
        }
      }
    }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu, openedAlbum: $openedAlbum, openedArtist: $openedArtist)
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
