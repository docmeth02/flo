//
//  WatchHomeView.swift
//  flo Watch App
//

import SwiftUI

struct WatchHomeView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @Environment(\.showPlayer) private var showPlayer
  @Environment(\.selectPlayerPage) private var selectPlayerPage
  @State private var openedAlbumId: String?
  @State private var menu: MenuTarget?

  var body: some View {
    List {
      if CoreDataManager.shared.isUsingVolatileStore {
        Section {
          StorageWarningRow()
        }
      }

      if playerViewModel.hasNowPlaying() {
        Button(action: selectPlayerPage) {
          NowPlayingIndicator()
        }
        .listRowBackground(Color.clear)
      }

      Button(action: {
        Task { if await playerViewModel.playSomething() { showPlayer() } }
      }) {
        Label(
          playerViewModel.isGeneratingMix ? "Building mix…" : "Play Something",
          systemImage: "sparkles"
        )
        .font(.headline)
      }
      .buttonStyle(FloPrimaryButtonStyle(height: 52))
      .opacity(playerViewModel.isGeneratingMix ? 0.6 : 1)
      .disabled(playerViewModel.isGeneratingMix)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      if !albumViewModel.recentAlbums.isEmpty {
        Section {
          ForEach(albumViewModel.recentAlbums) { album in
            CoverRow(
              tile: .album(album.id),
              title: album.name,
              subtitle: album.albumArtist)
            .holdable(onTap: { openedAlbumId = album.id }, onHold: { menu = .album(album) })
            .floRow()
          }
        } header: {
          FloSectionHeader("Recently Played")
        }
      }

      Section {
        NavigationLink(destination: WatchStarredSongsView()) {
          FloNavRow(title: "Liked Songs", systemImage: "heart.fill", tint: .floLiked)
        }
        .floRow()
        NavigationLink(destination: WatchArtistsListView()) {
          FloNavRow(title: "Artists", systemImage: "music.mic")
        }
        .floRow()
        NavigationLink(destination: WatchAlbumsListView()) {
          FloNavRow(title: "Albums", systemImage: "square.stack")
        }
        .floRow()
        NavigationLink(destination: WatchPlaylistsListView()) {
          FloNavRow(title: "Playlists", systemImage: "music.note.list")
        }
        .floRow()
        NavigationLink(destination: WatchRadiosView()) {
          FloNavRow(title: "Radios", systemImage: "dot.radiowaves.up.forward")
        }
        .floRow()
      } header: {
        FloSectionHeader("Library")
      }

      Section {
        NavigationLink(destination: WatchDownloadsView()) {
          FloNavRow(title: "Downloads", systemImage: "arrow.down.circle")
        }
        .floRow()
      } header: {
        FloSectionHeader("Offline")
      }

      Section {
        NavigationLink(destination: WatchSettingsView()) {
          FloNavRow(title: "Settings", systemImage: "gear", tint: .floSecondary)
        }
        .floRow()
      }
    }
    .scrollContentBackground(.hidden)
    .background(alignment: .top) {
      // Fixed behind the list like the mockup: rows scroll over the cover.
      if playerViewModel.hasNowPlaying() {
        CoverBackdrop(
          albumId: playerViewModel.nowPlaying.albumId ?? "",
          url: playerViewModel.coverArt, height: 190)
      }
    }
    .navigationDestination(item: $openedAlbumId) { id in
      if let album = albumViewModel.recentAlbums.first(where: { $0.id == id }) {
        WatchAlbumDetailView(album: album)
      }
    }
    .itemMenu($menu)
    .navigationTitle("")
    // Runs again on every return to Home, so a song just heard shows up.
    .task { await albumViewModel.loadRecentAlbums() }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Text("flo")
          .font(.floWordmark)
          .foregroundStyle(Color.floLavender)
      }
    }
    #if DEBUG
      .task { await runDebugFetchAlbums() }
    #endif
  }
}
