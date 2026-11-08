//
//  WatchCachedSongsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchCachedSongsView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel

  let songs: [Song]

  @Environment(\.showPlayer) private var showPlayer
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  var body: some View {
    List {
      SongRows(
        songs: songs,
        onHold: { menu = .song($0, context: SongCollection.Name.cached, isFromPlaylist: false) }
      ) {
        if playerViewModel.playItem(item: SongCollection.cached(songs), startingAt: $0) {
          showPlayer()
        }
      }
    }
    .listStyle(.plain)
    .brandNavigationTitle("Cached")
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu, openedAlbum: $openedAlbum, openedArtist: $openedArtist)
  }
}
