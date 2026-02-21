//
//  WatchHomeView.swift
//  flo Watch App
//

import SwiftUI

struct WatchHomeView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    List {
      if playerViewModel.hasNowPlaying() {
        NavigationLink(destination: WatchNowPlayingView()) {
          NowPlayingIndicator()
        }
      }

      Section("Library") {
        NavigationLink(destination: WatchArtistsListView()) {
          Label("Artists", systemImage: "music.mic")
        }
        NavigationLink(destination: WatchAlbumsListView()) {
          Label("Albums", systemImage: "square.stack")
        }
        NavigationLink(destination: WatchPlaylistsListView()) {
          Label("Playlists", systemImage: "music.note.list")
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
