//
//  WatchArtistDetailView.swift
//  flo Watch App
//

import SwiftUI
import Combine

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @StateObject var artistDetailViewModel = ArtistDetailViewModel()

  @State private var displayAlert: Bool = false

  let artist: Artist

  var body: some View {
    List {
      Section {
        Button(action: {
          artistDetailViewModel.fetchArtistRadio(artist: artist)
        }) {
          HStack {
            if artistDetailViewModel.isLoadingRadio {
              ProgressView()
            } else {
              Image(systemName: "dot.radiowaves.up.forward")
              Text("Artist Radio")
                .customFont(.caption1)
            }
          }
        }
        .disabled(artistDetailViewModel.isLoadingRadio || artistDetailViewModel.isLoadingTopSongs)

        Button(action: {
          artistDetailViewModel.fetchTopSongs(artist: artist)
        }) {
          HStack {
            if artistDetailViewModel.isLoadingTopSongs {
              ProgressView()
            } else {
              Image(systemName: "music.note.list")
              Text("Top Songs")
                .customFont(.caption1)
            }
          }
        }
        .disabled(artistDetailViewModel.isLoadingRadio || artistDetailViewModel.isLoadingTopSongs)
      }

      Section("Albums") {
        ForEach(albumViewModel.artistAlbums) { album in
          NavigationLink(destination: WatchAlbumDetailView(album: album)) {
            HStack(spacing: 8) {
              WatchAlbumArtView(
                url: albumViewModel.getAlbumCoverArt(id: album.id),
                size: 36,
                albumId: album.id
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
    }
    .navigationTitle(artist.name)
    .onAppear {
      albumViewModel.fetchAlbumsByArtist(id: artist.id)
    }
    .onReceive(artistDetailViewModel.playableSongs) { songs in
      if songs.isEmpty {
        displayAlert = true
      } else {
        let playable = RadioEntity(
          id: artist.id,
          name: "\(artist.name) Radio",
          songs: songs,
          artist: artist.name
        )
        playerViewModel.playItem(item: playable, isFromLocal: false)
      }
    }
    .alert("Artist Radio", isPresented: $displayAlert) {
      Button("OK") {
        artistDetailViewModel.errorMessage = nil
      }
    } message: {
      Text(artistDetailViewModel.errorMessage ?? "")
    }
  }
}
