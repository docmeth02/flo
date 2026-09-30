//
//  WatchContentView.swift
//  flo Watch App
//

import SwiftUI

struct WatchContentView: View {
  @StateObject private var authViewModel = AuthViewModel()
  @StateObject private var playerViewModel = WatchPlayerViewModel()
  @StateObject private var albumViewModel = AlbumViewModel()
  // Playback and scrobbling use the shared instance; Settings must show the
  // same state.
  @StateObject private var floooViewModel = FloooViewModel.shared
  @StateObject private var downloadViewModel = DownloadViewModel()
  @ObservedObject private var connectivity = ConnectivityMonitor.shared

  var body: some View {
    Group {
      if authViewModel.isLoggedIn {
        NavigationStack {
          TabView {
            WatchHomeView()

            if playerViewModel.hasNowPlaying() {
              WatchNowPlayingView()
            }
          }
          .tabViewStyle(.page)
        }
      } else {
        WatchLoginView(viewModel: authViewModel)
      }
    }
    .overlay(alignment: .top) {
      if !connectivity.isOnline {
        HStack(spacing: 4) {
          Image(systemName: "wifi.slash")
          Text("Offline")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary))
        .padding(.top, 2)
        .transition(.opacity)
      }
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
    .environmentObject(downloadViewModel)
    #if DEBUG
      .task { await runDebugDownloadActions() }
    #endif
  }
}

#if DEBUG
  // Simulator verification only. FLO_DEBUG_DOWNLOAD=album|playlist downloads
  // the smallest album or the first playlist of the library and logs the files
  // it produced; FLO_DEBUG_REMOVE=1 then removes it and logs what is left.
  extension WatchContentView {
    fileprivate func runDebugDownloadActions() async {
      let env = ProcessInfo.processInfo.environment
      guard let kind = env["FLO_DEBUG_DOWNLOAD"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)

      func songs(_ load: (@escaping (Result<[Song], Error>) -> Void) -> Void) async -> [Song] {
        await withCheckedContinuation { continuation in
          load { continuation.resume(returning: (try? $0.get()) ?? []) }
        }
      }

      var album: Album
      var playlist: Playlist?
      if kind == "playlist" {
        let playlists: [Playlist] = await withCheckedContinuation { continuation in
          AlbumService.shared.getPlaylists { continuation.resume(returning: (try? $0.get()) ?? []) }
        }
        guard var first = playlists.first else { return debugLog("no playlists") }
        first.songs = await songs { AlbumService.shared.getSongsByPlaylist(id: first.id, completion: $0) }
        playlist = first
        album = Album(from: first)
        albumViewModel.downloadPlaylist(first)
      } else {
        let albums: [Album] = await withCheckedContinuation { continuation in
          AlbumService.shared.getAlbum { result in
            if case .failure(let error) = result { debugLog("albums failed: \(error)") }
            continuation.resume(returning: (try? result.get()) ?? [])
          }
        }
        var smallest: Album?
        for candidate in albums.prefix(10) {
          var loaded = candidate
          loaded.songs = await songs {
            AlbumService.shared.getSongFromAlbum(id: candidate.id, completion: $0)
          }
          if !loaded.songs.isEmpty, loaded.songs.count < (smallest?.songs.count ?? .max) {
            smallest = loaded
          }
        }
        guard let smallest else { return debugLog("no albums") }
        album = smallest
        albumViewModel.downloadAlbum(album)
      }

      debugLog("downloading \(kind) \(album.id) with \(album.songs.count) songs")
      downloadViewModel.addItem(album, isFromPlaylist: playlist != nil)

      for _ in 0..<120 where downloadViewModel.isDownloading(album.name) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      logMediaFiles("after download")

      guard env["FLO_DEBUG_REMOVE"] == "1" else { return }
      if let playlist {
        albumViewModel.removeDownloadedPlaylist(playlist: playlist)
      } else {
        albumViewModel.removeDownloadedAlbum(album: album)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      logMediaFiles("after removal")
    }

    private func logMediaFiles(_ label: String) {
      guard let media = LocalFileManager.shared.fileURL(for: "Media") else { return }
      let files = FileManager.default.enumerator(atPath: media.path)?
        .compactMap { $0 as? String } ?? []
      let songs = CoreDataManager.shared.countRecords(entity: SongEntity.self)
      let collections = CoreDataManager.shared.countRecords(entity: PlaylistEntity.self)
      debugLog("\(label): songs=\(songs) collections=\(collections) files=\(files.sorted())")
    }
  }
#endif
