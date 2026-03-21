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

      Button(action: {
        var allSongs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
        let albums = LibraryCacheManager.shared.load([Album].self, forKey: "albums") ?? []
        if allSongs.isEmpty {
          AlbumService.shared.getAllSongs { result in
            DispatchQueue.main.async {
              if case .success(let songs) = result {
                allSongs = songs
                LibraryCacheManager.shared.save(songs, forKey: "songs")
              }
              let recs = SmartPlaybackService.shared.generateRecommendations(
                count: 15, allSongs: allSongs, albums: albums)
              if !recs.isEmpty {
                let mix = SongCollection(id: "smart-shuffle", name: "Smart Shuffle", songs: recs)
                playerViewModel.playItem(item: mix, isFromLocal: false)
              }
            }
          }
        } else {
          let recs = SmartPlaybackService.shared.generateRecommendations(
            count: 15, allSongs: allSongs, albums: albums)
          if !recs.isEmpty {
            let mix = SongCollection(id: "smart-shuffle", name: "Smart Shuffle", songs: recs)
            playerViewModel.playItem(item: mix, isFromLocal: false)
          }
        }
      }) {
        Label("Play Something", systemImage: "sparkles")
      }

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
