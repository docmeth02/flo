//
//  WatchStarredSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @Environment(\.showPlayer) private var showPlayer

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
        let isCurrentlyPlaying =
          playerViewModel.hasNowPlaying()
          && playerViewModel.nowPlaying.id == (song.mediaFileId.isEmpty ? song.id : song.mediaFileId)

        TrackRowView(
          trackNumber: idx + 1,
          title: song.title,
          artist: song.artist,
          isPlaying: isCurrentlyPlaying
        ) {
          let liked = SongCollection(id: "starred-songs", name: "Liked Songs", songs: albumViewModel.starredSongs)
          if playerViewModel.playBySong(idx: idx, item: liked, isFromLocal: false) { showPlayer() }
        }
        .listRowBackground(Color.clear)
      }
    }
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
