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
  @State private var isGeneratingMix = false

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
        guard !isGeneratingMix else { return }
        isGeneratingMix = true
        let generation = playerViewModel.startGeneration

        Task { @MainActor in
          let songs = await SmartPlaybackService.shared.generateMix(count: 15, mode: .playSomething)
          isGeneratingMix = false

          // The user started something else while the mix was built.
          guard !songs.isEmpty, playerViewModel.startGeneration == generation else { return }
          let mix = SongCollection(id: "smart-shuffle", name: "Smart Shuffle", songs: songs)
          if playerViewModel.playItem(item: mix, isFromLocal: false) { showPlayer() }
        }
      }) {
        Label(isGeneratingMix ? "Building mix…" : "Play Something", systemImage: "sparkles")
          .font(.headline)
      }
      .buttonStyle(FloPrimaryButtonStyle(height: 52))
      .opacity(isGeneratingMix ? 0.6 : 1)
      .disabled(isGeneratingMix)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

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
    .navigationTitle("")
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
