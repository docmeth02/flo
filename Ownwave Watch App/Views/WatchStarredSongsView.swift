//
//  WatchStarredSongsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @ObservedObject private var starStore = StarStore.shared

  @Environment(\.showPlayer) private var showPlayer
  @State private var menu: MenuTarget?

  /// Unliked songs leave at once, before the list reloads.
  private var songs: [Song] {
    albumViewModel.starredSongs.filter { playerViewModel.isStarred($0) }
  }

  var body: some View {
    let songs = songs
    LibraryList(
      title: "Liked Songs", state: albumViewModel.state(.starredSongs),
      isEmpty: songs.isEmpty,
      empty: .empty(
        systemImage: "heart.fill", tint: .floLiked, title: "No liked songs yet",
        message: "Tap the heart on Now Playing to add a song here."),
      refresh: albumViewModel.refreshStarredSongs
    ) {
      ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
        TrackRowView(
          trackNumber: idx + 1,
          title: song.title,
          artist: song.artist,
          isPlaying: playerViewModel.isCurrent(song),
          onHold: { menu = .song(song, context: SongCollection.Name.liked, isFromPlaylist: false) }
        ) {
          let liked = SongCollection.liked(songs)
          if playerViewModel.playItem(item: liked, startingAt: idx) { showPlayer() }
        }
        // The row's own platter, as wide as the platters of other lists.
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
    }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
