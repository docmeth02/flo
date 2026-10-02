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

        Task { @MainActor in
          let songs = await SmartPlaybackService.shared.generateMix(count: 15, mode: .playSomething)
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
    #if DEBUG
      .task { await runDebugFetchAlbums() }
    #endif
  }
}

#if DEBUG
  // Simulator verification only. FLO_DEBUG_FETCH_ALBUMS=1 loads the album list
  // two seconds after launch, =now right away (racing the launch re-login), and
  // logs what the request log recorded.
  extension WatchHomeView {
    fileprivate func runDebugFetchAlbums() async {
      let mode = ProcessInfo.processInfo.environment["FLO_DEBUG_FETCH_ALBUMS"]
      guard mode == "1" || mode == "now" else { return }
      if mode == "1" { try? await Task.sleep(nanoseconds: 2_000_000_000) }
      albumViewModel.fetchAlbums()
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      let entries = RequestLog.shared.entries
      debugLog("request log: \(entries.count) entries")
      for entry in entries.reversed() {
        debugLog(
          "  \(entry.text) status=\(entry.status.map(String.init) ?? "-") retries=\(entry.retries) error=\(entry.error ?? "-")"
        )
      }
    }
  }
#endif
