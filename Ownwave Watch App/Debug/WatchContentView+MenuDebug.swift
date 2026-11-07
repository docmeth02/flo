//
//  WatchContentView+MenuDebug.swift
//  Ownwave Watch App
//

#if DEBUG
  import SwiftUI

  extension WatchContentView {
    /// FLO_DEBUG_PIN=<album|artist|playlist|radio>:<id> toggles a pin at launch,
    /// FLO_DEBUG_STAR=album:<id>|artist:<id> a star through StarStore, which
    /// logs when the server took it. FLO_DEBUG_STAR_PENDING=1 logs the stars
    /// still waiting from the last session.
    /// FLO_DEBUG_MENU=song|album|artist|playlist|radio opens the hold menu for
    /// the first track of the first album, or the first album, artist,
    /// playlist or station over its screen, for screenshots;
    /// FLO_DEBUG_MENU_SCREEN=home|search opens a song or album menu over Home
    /// or Search instead. FLO_DEBUG_MENU_ACTION=boost|avoid|album|artist then
    /// runs that row a second later; a comma list runs the next on the
    /// screen the row opened, on the same item (song over Home with
    /// album,artist pushes its album, then its artist on top).
    func runDebugMenuActions() async {
      // A closing sheet makes the root view appear again, which reruns the
      // launch hooks: a pin would toggle back, the menu's rows run again.
      guard !DebugMenuScript.hasRun else { return }
      DebugMenuScript.hasRun = true
      let env = ProcessInfo.processInfo.environment
      if env["FLO_DEBUG_STAR_PENDING"] == "1" {
        let pending = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.pendingStars) ?? [:]
        debugLog("star hook: \(pending.count) pending \(pending)")
      }
      if case (let kind, let id)? = env["FLO_DEBUG_PIN"].flatMap(Self.debugItem) {
        PinStore.shared.toggle(id, kind)
        debugLog("pin hook: \(kind) \(id) pinned=\(PinStore.shared.isPinned(id, kind))")
      }
      guard env["FLO_DEBUG_STAR"] != nil || env["FLO_DEBUG_MENU"] != nil else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      let albums = (try? await LibraryAPI.getAlbum()) ?? []
      let artists = (try? await LibraryAPI.getArtists()) ?? []

      if case (let kind, let id)? = env["FLO_DEBUG_STAR"].flatMap(Self.debugItem) {
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

      var screen: AnyView
      let target: MenuTarget
      switch env["FLO_DEBUG_MENU"] {
      case "song":
        guard var album = albums.first else { return debugLog("menu hook: no albums") }
        album.songs = (try? await LibraryAPI.getSongFromAlbum(id: album.id)) ?? []
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
      case "playlist":
        guard let playlist = try? await LibraryAPI.getPlaylists().first else {
          return debugLog("menu hook: no playlists")
        }
        screen = AnyView(WatchPlaylistsListView())
        target = .playlist(playlist)
      case "radio":
        guard let radio = try? await RadioService.shared.getAllRadios().first else {
          return debugLog("menu hook: no radios")
        }
        screen = AnyView(WatchRadiosView())
        target = .radio(radio)
      case nil: return
      case let other?: return debugLog("menu hook: unknown item \(other)")
      }
      switch env["FLO_DEBUG_MENU_SCREEN"] {
      case "home": screen = AnyView(WatchHomeView())
      case "search": screen = AnyView(WatchSearchView(query: target.title))
      default: break
      }
      let rating = MenuActions(player: playerViewModel, pins: .shared, stars: .shared)
        .ownRating(target)
      debugLog("menu hook: showing \(target.id) rating=\(rating.map(String.init) ?? "-")")
      DebugMenuScript.target = target
      DebugMenuScript.actions =
        env["FLO_DEBUG_MENU_ACTION"]?.split(separator: ",").map(String.init) ?? []
      debugScreen = DebugScreen(view: screen)
    }

    /// "<kind>:<id>", a `PinStore.Kind` such as "album:<id>".
    private static func debugItem(_ value: String) -> (PinStore.Kind, String)? {
      let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, let kind = PinStore.Kind(rawValue: parts[0]) else { return nil }
      return (kind, parts[1])
    }
  }

  extension View {
    /// FLO_DEBUG_MENU_SCROLL=1 opens the hold menu scrolled to its end, for
    /// screenshots of the rows below the fold.
    func debugMenuScroll() -> some View {
      defaultScrollAnchor(
        ProcessInfo.processInfo.environment["FLO_DEBUG_MENU_SCROLL"] == "1" ? .bottom : nil)
    }
  }

  /// What FLO_DEBUG_MENU opens and the rows it runs, taken by the screen on
  /// top.
  @MainActor enum DebugMenuScript {
    static var target: MenuTarget?
    static var actions: [String] = []
    static var hasRun = false
  }

  /// On each screen with a hold menu: once the screen has been on top for a
  /// moment, opens the scripted menu over it and runs its next row there.
  struct DebugMenuRunner: ViewModifier {
    @Binding var target: MenuTarget?
    let goTo: (MenuTarget) -> [ItemMenu.Choice]
    let select: (ItemMenu.Choice, MenuTarget) -> Void

    func body(content: Content) -> some View {
      content.task {
        // Cancelled when another screen is pushed meanwhile.
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled, let menu = DebugMenuScript.target else { return }
        target = menu
        guard !DebugMenuScript.actions.isEmpty else {
          DebugMenuScript.target = nil
          return
        }
        let action = DebugMenuScript.actions.removeFirst()
        if DebugMenuScript.actions.isEmpty { DebugMenuScript.target = nil }
        let choice: ItemMenu.Choice
        switch action {
        case "boost": choice = .action(.boost)
        case "avoid": choice = .action(.avoid)
        case "album": choice = .goToAlbum
        case "artist": choice = .goToArtist
        default: return debugLog("menu hook: unknown action \(action)")
        }
        if choice.opens, !goTo(menu).contains(choice) {
          return debugLog("menu hook: \(action) is not offered here")
        }
        // Not this task: the sheet may count as leaving the screen.
        Task {
          try? await Task.sleep(for: .seconds(1))
          debugLog("menu hook: runs \(action) on \(menu.id)")
          select(choice, menu)
        }
      }
    }
  }
#endif
