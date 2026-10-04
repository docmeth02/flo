//
//  WatchCachedSongsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchCachedSongsView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  let songs: [Song]

  @Environment(\.showPlayer) private var showPlayer
  @State private var menu: MenuTarget?

  var body: some View {
    List {
      ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
        TrackRowView(
          trackNumber: idx + 1,
          title: song.title,
          artist: song.artist,
          isPlaying: playerViewModel.isCurrent(song),
          onHold: { menu = .song(song, context: "Cached", isFromPlaylist: false) }
        ) {
          let cached = SongCollection(id: "cached-songs", name: "Cached", songs: songs)
          if playerViewModel.playBySong(idx: idx, item: cached, isFromLocal: true) { showPlayer() }
        }
        .listRowBackground(Color.clear)
      }
    }
    .navigationTitle("Cached")
    .itemMenu($menu)
  }
}
