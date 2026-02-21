//
//  WatchArtistDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  let artist: Artist

  var body: some View {
    List {
      ForEach(albumViewModel.artistAlbums) { album in
        NavigationLink(destination: WatchAlbumDetailView(album: album)) {
          HStack(spacing: 8) {
            WatchAlbumArtView(
              url: albumViewModel.getAlbumCoverArt(id: album.id),
              size: 36
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
              Text(album.name)
                .customFont(.caption1)
                .lineLimit(1)

              if album.minYear > 0 {
                Text("\(String(album.minYear))")
                  .customFont(.caption2)
                  .foregroundColor(.secondary)
              }
            }
          }
        }
      }
    }
    .navigationTitle(artist.name)
    .onAppear {
      albumViewModel.fetchAlbumsByArtist(id: artist.id)
    }
  }
}
