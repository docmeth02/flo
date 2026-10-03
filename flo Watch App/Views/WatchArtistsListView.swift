//
//  WatchArtistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  private var placeholder: StateView.Kind {
    if albumViewModel.state(.artists).isLoading { return .loading }
    if albumViewModel.state(.artists).failed {
      return .error(retry: { Task { await albumViewModel.refreshArtists() } })
    }
    return .empty(
      systemImage: "music.mic", tint: .floLavender, title: "No artists",
      message: "Artists on your Navidrome server show up here.")
  }

  var body: some View {
    Group {
      if albumViewModel.artists.isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List {
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
      }
    }
    .navigationTitle("Artists")
    .refreshable {
      await albumViewModel.refreshArtists()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.state(.artists).isLoading {
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
