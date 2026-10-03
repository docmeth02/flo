//
//  WatchArtistDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @Environment(\.showPlayer) private var showPlayer

  @StateObject var artistDetailViewModel = ArtistDetailViewModel()

  @State private var displayAlert: Bool = false

  let artist: Artist

  var body: some View {
    List {
      Section {
        Button(action: {
          artistDetailViewModel.fetchArtistRadio(artist: artist)
        }) {
          if artistDetailViewModel.isLoadingRadio {
            ProgressView()
          } else {
            Label("Artist Radio", systemImage: "dot.radiowaves.up.forward")
          }
        }
        .capsuleRow()

        Button(action: {
          artistDetailViewModel.fetchTopSongs(artist: artist)
        }) {
          if artistDetailViewModel.isLoadingTopSongs {
            ProgressView()
          } else {
            Label("Top Songs", systemImage: "music.note.list")
          }
        }
        .capsuleRow()
      }
      .disabled(artistDetailViewModel.isLoadingRadio || artistDetailViewModel.isLoadingTopSongs)

      Section {
        ForEach(albumViewModel.albums(byArtist: artist.id)) { album in
          NavigationLink(destination: WatchAlbumDetailView(album: album)) {
            CoverRow(
              tile: .cover(url: albumViewModel.getAlbumCoverArt(id: album.id), albumId: album.id),
              title: album.name,
              subtitle: album.minYear > 0 ? String(album.minYear) : "")
          }
          .floRow()
        }
      } header: {
        FloSectionHeader("Albums")
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
        if playerViewModel.playItem(item: playable, isFromLocal: false) { showPlayer() }
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

extension View {
  /// A capsule button as a whole list row, without the row platter.
  fileprivate func capsuleRow() -> some View {
    buttonStyle(FloTintedButtonStyle())
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
  }
}
