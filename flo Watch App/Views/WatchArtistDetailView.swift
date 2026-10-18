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
  @State private var openedAlbum: Album?
  @State private var menu: MenuTarget?

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
          CoverRow(
            tile: .album(album.id),
            title: album.name,
            subtitle: album.minYear > 0 ? String(album.minYear) : "")
          .holdable(onTap: { openedAlbum = album }, onHold: { menu = .album(album) })
          .floRow()
        }
      } header: {
        FloSectionHeader("Albums")
      }
    }
    .floNavigationTitle(artist.name)
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.fetchAlbumsByArtist(id: artist.id)
    }
    .onReceive(artistDetailViewModel.playableSongs) { songs in
      if songs.isEmpty {
        displayAlert = true
      } else {
        let playable = SongCollection(id: artist.id, name: "\(artist.name) Radio", songs: songs)
        if playerViewModel.playItem(item: playable) { showPlayer() }
      }
    }
    .alert(artist.name, isPresented: $displayAlert) {
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
