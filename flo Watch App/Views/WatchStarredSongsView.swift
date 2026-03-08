//
//  WatchStarredSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @State private var showNowPlaying = false

  var body: some View {
    List {
      if albumViewModel.starredSongs.isEmpty {
        Text("No liked songs yet")
          .customFont(.caption1)
          .foregroundColor(.secondary)
          .listRowBackground(Color.clear)
      } else {
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
            playerViewModel.playBySong(idx: idx, item: liked, isFromLocal: false)
            showNowPlaying = true
          }
        }
      }
    }
    .navigationTitle("Liked Songs")
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
