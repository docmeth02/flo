//
//  WatchStarredSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchStarredSongsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @State private var showNowPlaying = false

  private var placeholder: StateView.Kind {
    if albumViewModel.isLoading { return .loading }
    if albumViewModel.error != nil {
      return .error(retry: { Task { await albumViewModel.refreshStarredSongs() } })
    }
    return .empty(
      systemImage: "heart.fill", tint: .floLiked, title: "No liked songs yet",
      message: "Tap the heart on Now Playing to add a song here.")
  }

  var body: some View {
    Group {
      if albumViewModel.starredSongs.isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List {
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
              showNowPlaying = playerViewModel.playBySong(idx: idx, item: liked, isFromLocal: false)
            }
            .listRowBackground(Color.clear)
          }
        }
      }
    }
    .navigationTitle("Liked Songs")
    .refreshable {
      await albumViewModel.refreshStarredSongs()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshStarredSongs() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .onAppear {
      albumViewModel.fetchStarredSongs()
    }
  }
}
