//
//  WatchCachedSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchCachedSongsView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  let songs: [Song]

  @State private var showNowPlaying = false

  var body: some View {
    List {
      ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
        let isCurrentlyPlaying =
          playerViewModel.hasNowPlaying()
          && playerViewModel.nowPlaying.id == song.mediaFileId

        TrackRowView(
          trackNumber: idx + 1,
          title: song.title,
          artist: song.artist,
          isPlaying: isCurrentlyPlaying
        ) {
          let cached = SongCollection(id: "cached-songs", name: "Cached", songs: songs)
          playerViewModel.playBySong(idx: idx, item: cached, isFromLocal: true)
          showNowPlaying = true
        }
      }
    }
    .navigationTitle("Cached")
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
  }
}
