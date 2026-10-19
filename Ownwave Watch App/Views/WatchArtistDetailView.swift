//
//  WatchArtistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @Environment(\.showPlayer) private var showPlayer

  @StateObject var artistDetailViewModel = ArtistDetailViewModel()

  @State private var displayAlert: Bool = false
  @State private var isLoadingTopSongs = false
  @State private var openedAlbum: Album?
  @State private var menu: MenuTarget?

  let artist: Artist

  var body: some View {
    List {
      Section {
        Button(action: {
          Task {
            let songs = await artistDetailViewModel.fetchArtistRadio(artist: artist)
            let radio = SongCollection.artistRadio(id: artist.id, name: artist.name, songs: songs)
            if songs.isEmpty {
              displayAlert = true
            } else if playerViewModel.playItem(item: radio) {
              showPlayer()
            }
          }
        }) {
          if artistDetailViewModel.isLoadingRadio {
            ProgressView()
          } else {
            Label("Artist Radio", systemImage: "dot.radiowaves.up.forward")
          }
        }
        .capsuleRow()

        // Top songs online, else the artist's songs on the watch, as Siri
        // plays an artist.
        Button(action: {
          Task {
            isLoadingTopSongs = true
            if await playerViewModel.playArtist(id: artist.id, name: artist.name) { showPlayer() }
            isLoadingTopSongs = false
          }
        }) {
          if isLoadingTopSongs {
            ProgressView()
          } else {
            Label("Top Songs", systemImage: "music.note.list")
          }
        }
        .capsuleRow()
      }
      .disabled(artistDetailViewModel.isLoadingRadio || playerViewModel.isGeneratingMix)

      Section {
        ForEach(albumViewModel.albums(byArtist: artist.id)) { album in
          CoverRow(
            tile: .cover(albumId: album.id),
            title: album.name,
            subtitle: album.minYear > 0 ? String(album.minYear) : ""
          )
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
    .alert(artist.name, isPresented: $displayAlert) {
      Button("OK") {}
    } message: {
      Text(ArtistDetailViewModel.noRadioMessage)
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
