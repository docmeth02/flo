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
          HStack(spacing: 10) {
            Image(systemName: "music.mic")
              .font(.system(size: 16))
              .foregroundStyle(Color.floLavender)
              .frame(width: 36, height: 36)
              .background(Circle().fill(Color.floLavender.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
              Text(artist.name)
                .font(.floRowTitle)
                .lineLimit(1)
              if artist.albumCount > 0 {
                Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
                  .font(.floMeta)
                  .foregroundStyle(Color.floSecondary)
                  .lineLimit(1)
              }
            }
          }
          .frame(minHeight: 52)
        }
        .floRow()
      }
    }
    .onAppear {
      albumViewModel.getArtists()
    }
  }
}
