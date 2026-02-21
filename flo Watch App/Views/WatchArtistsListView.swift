//
//  WatchArtistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    List {
      ForEach(albumViewModel.artists) { artist in
        NavigationLink(destination: WatchArtistDetailView(artist: artist)) {
          Text(artist.name)
            .customFont(.caption1)
            .lineLimit(1)
        }
      }
    }
    .navigationTitle("Artists")
    .onAppear {
      albumViewModel.getArtists()
    }
  }
}
