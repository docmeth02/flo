//
//  WatchContentView+MenuDebug.swift
//  flo Watch App
//

#if DEBUG
  import SwiftUI

  extension WatchContentView {
    /// FLO_DEBUG_PIN=album:<id>|artist:<id> toggles a pin at launch,
    /// FLO_DEBUG_STAR=album:<id>|artist:<id> a star through StarStore, which
    /// logs when the server took it. FLO_DEBUG_STAR_PENDING=1 logs the stars
    /// still waiting from the last session. FLO_DEBUG_MENU=song|album|artist
    /// opens the hold menu for the first track of the first album, the first
    /// album or the first artist over its screen, for screenshots.
    func runDebugMenuActions() async {
      let env = ProcessInfo.processInfo.environment
      if env["FLO_DEBUG_STAR_PENDING"] == "1" {
        let pending = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.pendingStars) ?? [:]
        debugLog("star hook: \(pending.count) pending \(pending)")
      }
      if case let (kind, id)? = env["FLO_DEBUG_PIN"].flatMap(Self.debugItem) {
        PinStore.shared.toggle(id, kind)
        debugLog("pin hook: \(kind) \(id) pinned=\(PinStore.shared.isPinned(id, kind))")
      }
      guard env["FLO_DEBUG_STAR"] != nil || env["FLO_DEBUG_MENU"] != nil else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      let albums: [Album] = await Self.debugLoad(AlbumService.shared.getAlbum)
      let artists: [Artist] = await Self.debugLoad(AlbumService.shared.getArtists)

      if case let (kind, id)? = env["FLO_DEBUG_STAR"].flatMap(Self.debugItem) {
        // The cached lists when offline, where the requests above fail.
        let listed =
          kind == .album
          ? await albumViewModel.loadedOrCached(albums, .albums).first { $0.id == id }?.starred
          : await albumViewModel.loadedOrCached(artists, .artists).first { $0.id == id }?.starred
        if let listed {
          let starred = StarStore.shared.isStarred(id, listed: listed)
          debugLog("star hook: \(kind) \(id) was starred=\(starred)")
          StarStore.shared.set(!starred, id: id)
        } else {
          debugLog("star hook: \(kind) \(id) not found")
        }
      }

      let screen: AnyView
      let target: MenuTarget
      switch env["FLO_DEBUG_MENU"] {
      case "song":
        guard var album = albums.first else { return debugLog("menu hook: no albums") }
        album.songs = await Self.debugLoad {
          AlbumService.shared.getSongFromAlbum(id: album.id, completion: $0)
        }
        guard let song = album.songs.first else { return debugLog("menu hook: no songs") }
        screen = AnyView(WatchAlbumDetailView(album: album))
        target = .song(song, context: album.name, isFromPlaylist: false)
      case "album":
        guard let album = albums.first else { return debugLog("menu hook: no albums") }
        screen = AnyView(WatchAlbumsListView())
        target = .album(album)
      case "artist":
        guard let artist = artists.first else { return debugLog("menu hook: no artists") }
        screen = AnyView(WatchArtistsListView())
        target = .artist(artist)
      case nil: return
      case let other?: return debugLog("menu hook: unknown item \(other)")
      }
      debugLog("menu hook: showing \(target.id)")
      debugScreen = DebugScreen(view: AnyView(DebugMenuScreen(content: screen, target: target)))
    }

    /// "album:<id>" or "artist:<id>".
    private static func debugItem(_ value: String) -> (PinStore.Kind, String)? {
      let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, let kind = PinStore.Kind(rawValue: parts[0]) else { return nil }
      return (kind, parts[1])
    }

    private static func debugLoad<T>(
      _ call: (@escaping (Result<[T], Error>) -> Void) -> Void
    ) async -> [T] {
      await withCheckedContinuation { continuation in
        call { continuation.resume(returning: (try? $0.get()) ?? []) }
      }
    }
  }

  /// A screen that opens the hold menu for `target` once it is on screen.
  private struct DebugMenuScreen: View {
    let content: AnyView
    let target: MenuTarget
    @State private var menu: MenuTarget?

    var body: some View {
      content
        .itemMenu($menu)
        .task {
          try? await Task.sleep(nanoseconds: 1_500_000_000)
          menu = target
        }
    }
  }
#endif
