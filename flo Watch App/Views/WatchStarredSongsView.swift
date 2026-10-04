//
//  WatchStarredSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @Environment(\.showPlayer) private var showPlayer
  @State private var menu: MenuTarget?

  var body: some View {
    LibraryList(
      title: "Liked Songs", state: albumViewModel.state(.starredSongs),
      isEmpty: albumViewModel.starredSongs.isEmpty,
      empty: .empty(
        systemImage: "heart.fill", tint: .floLiked, title: "No liked songs yet",
        message: "Tap the heart on Now Playing to add a song here."),
      refresh: albumViewModel.refreshStarredSongs
    ) {
      ForEach(Array(albumViewModel.starredSongs.enumerated()), id: \.element.id) { idx, song in
        TrackRowView(
          trackNumber: idx + 1,
          title: song.title,
          artist: song.artist,
          isPlaying: playerViewModel.isCurrent(song),
          onHold: { menu = .song(song, context: "Liked Songs", isFromPlaylist: false) }
        ) {
          let liked = SongCollection(id: "starred-songs", name: "Liked Songs", songs: albumViewModel.starredSongs)
          if playerViewModel.playBySong(idx: idx, item: liked, isFromLocal: false) { showPlayer() }
        }
        .listRowBackground(Color.clear)
      }
    }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
