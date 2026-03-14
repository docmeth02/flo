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
    .refreshable {
      await albumViewModel.refreshArtists()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshArtists() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .onAppear {
      albumViewModel.getArtists()
    }
  }
}
