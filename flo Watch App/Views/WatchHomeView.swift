//
//  WatchHomeView.swift
//  flo Watch App
//

import SwiftUI

struct WatchHomeView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @State private var isGeneratingMix = false

  var body: some View {
    List {
      if playerViewModel.hasNowPlaying() {
        NavigationLink(destination: WatchNowPlayingView()) {
          NowPlayingIndicator()
        }
      }

      Button(action: {
        guard !isGeneratingMix else { return }
        isGeneratingMix = true

        Task {
          let songs = await SmartPlaybackService.shared.generateMix(count: 15)
          isGeneratingMix = false

          guard !songs.isEmpty else { return }
          let mix = SongCollection(id: "smart-shuffle", name: "Smart Shuffle", songs: songs)
          playerViewModel.playItem(item: mix, isFromLocal: false)
        }
      }) {
        Label("Play Something", systemImage: "sparkles")
      }
      .disabled(isGeneratingMix)

      Section("Library") {
        NavigationLink(destination: WatchStarredSongsView()) {
          Label("Liked Songs", systemImage: "heart.fill")
        }
        NavigationLink(destination: WatchArtistsListView()) {
          Label("Artists", systemImage: "music.mic")
        }
        NavigationLink(destination: WatchAlbumsListView()) {
          Label("Albums", systemImage: "square.stack")
        }
        NavigationLink(destination: WatchPlaylistsListView()) {
          Label("Playlists", systemImage: "music.note.list")
        }
        NavigationLink(destination: WatchRadiosView()) {
          Label("Radios", systemImage: "dot.radiowaves.up.forward")
        }
      }

      Section("Offline") {
        NavigationLink(destination: WatchDownloadsView()) {
          Label("Downloads", systemImage: "arrow.down.circle")
        }
      }

      Section {
        NavigationLink(destination: WatchSettingsView()) {
          Label("Settings", systemImage: "gear")
        }
      }
    }
    .navigationTitle("flo")
  }
}
