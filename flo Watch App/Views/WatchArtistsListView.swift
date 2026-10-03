//
//  WatchArtistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    LibraryList(
      title: "Artists", state: albumViewModel.state(.artists),
      isEmpty: albumViewModel.artists.isEmpty,
      empty: .empty(
        systemImage: "music.mic", tint: .floLavender, title: "No artists",
        message: "Artists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshArtists
    ) {
      ForEach(albumViewModel.artists) { artist in
        NavigationLink(destination: WatchArtistDetailView(artist: artist)) {
          CoverRow(
            tile: .glyph("music.mic", round: true),
            title: artist.name,
            subtitle: artist.albumCount > 0
              ? counted(artist.albumCount, "album") : "")
        }
        .floRow()
      }
    }
    .onAppear {
      albumViewModel.getArtists()
    }
  }
}
