//
//  WatchCachedSongsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchCachedSongsView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

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
          onHold: { menu = .song(song, context: SongCollection.Name.cached, isFromPlaylist: false) }
        ) {
          let cached = SongCollection.cached(songs)
          if playerViewModel.playItem(item: cached, startingAt: idx) { showPlayer() }
        }
        // The row's own platter, as in Liked Songs.
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.plain)
    .floNavigationTitle("Cached")
    .itemMenu($menu)
  }
}
