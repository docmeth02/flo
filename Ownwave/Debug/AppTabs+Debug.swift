//
//  AppTabs+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_SCREEN=home|library|search|
  // settings|album|artist|playlist|nowplaying opens that screen once the
  // library answered (album, artist and playlist: the first of each, or the
  // one named by FLO_DEBUG_SCREEN_ID), for screenshots.
  extension AppTabs {
    func runDebugScreen() async {
      let env = ProcessInfo.processInfo.environment
      guard let screen = env["FLO_DEBUG_SCREEN"] else { return }
      let id = env["FLO_DEBUG_SCREEN_ID"]
      try? await Task.sleep(for: .seconds(2))
      func pick<T: Identifiable>(_ items: [T]) -> T? where T.ID == String {
        id.flatMap { id in items.first { $0.id == id } } ?? items.first
      }
      switch screen {
      case "library": tab = .library
      case "search": tab = .search
      case "settings": paths[.home, default: NavigationPath()].append(Route.settings)
      case "album":
        let albums: [Album] = await Self.debugLoad(AlbumService.shared.getAlbum)
        if let album = pick(albums) { paths[.home, default: NavigationPath()].append(Route.album(album)) }
      case "artist":
        let artists: [Artist] = await Self.debugLoad(AlbumService.shared.getArtists)
        if let artist = pick(artists) {
          paths[.home, default: NavigationPath()].append(Route.artist(artist))
        }
      case "playlist":
        let playlists: [Playlist] = await Self.debugLoad(AlbumService.shared.getPlaylists)
        if let playlist = pick(playlists) {
          paths[.home, default: NavigationPath()].append(Route.playlist(playlist))
        }
      case "nowplaying": app.isNowPlayingPresented = true
      default: break
      }
      debugLog("screen hook: \(screen)")
    }

    private static func debugLoad<T>(
      _ load: (@escaping (Result<[T], Error>) -> Void) -> Void
    ) async -> [T] {
      await withCheckedContinuation { continuation in
        load { continuation.resume(returning: (try? $0.get()) ?? []) }
      }
    }
  }
#endif
