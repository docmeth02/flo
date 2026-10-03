//
//  WatchContentView.swift
//  flo Watch App
//

import SwiftUI

extension EnvironmentValues {
  /// Leaves the library for the player page; set by WatchContentView.
  @Entry var showPlayer: () -> Void = {}
  /// Selects the player page without popping, for the root of the stack:
  /// a reset there would rebuild Home mid-mix and re-enable Play Something.
  @Entry var selectPlayerPage: () -> Void = {}
}

struct WatchContentView: View {
  @StateObject private var authViewModel = AuthViewModel()
  @StateObject private var playerViewModel = WatchPlayerViewModel()
  @StateObject private var albumViewModel = AlbumViewModel()
  // Playback and scrobbling use the shared instance; Settings must show the
  // same state.
  @StateObject private var floooViewModel = FloooViewModel.shared
  @StateObject private var downloadViewModel = DownloadViewModel()
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @Environment(\.scenePhase) private var scenePhase

  @State private var selectedTab = Tab.home
  // Recreating the stack pops whatever was browsed on top of the tabs.
  @State private var stackID = UUID()
  @State private var leftAt: Date?
  #if DEBUG
    @State private var showsDebugDiagnostics = false
    @State private var debugScreen: DebugScreen?
    @State private var debugLoginScreen: DebugScreen?
  #endif

  private enum Tab { case home, nowPlaying }

  /// Pops whatever was browsed and selects the player page, so there is only
  /// one player. The rebuilt page view starts on its first page; the player is
  /// selected once it is in place. Resetting first makes that a real change
  /// when the player was already selected.
  private func showPlayer() {
    selectedTab = .home
    stackID = UUID()
    DispatchQueue.main.async { selectedTab = .nowPlaying }
  }

  var body: some View {
    Group {
      if authViewModel.isLoggedIn {
        NavigationStack {
          TabView(selection: $selectedTab) {
            WatchHomeView()
              .tag(Tab.home)

            if playerViewModel.hasNowPlaying() {
              WatchNowPlayingView(ownsCrown: selectedTab == .nowPlaying)
                .tag(Tab.nowPlaying)
            }
          }
          .tabViewStyle(.page)
          #if DEBUG
            .navigationDestination(item: $debugScreen) { $0.view }
          #endif
        }
        .id(stackID)
        .environment(\.showPlayer, showPlayer)
        .environment(\.selectPlayerPage) { selectedTab = .nowPlaying }
      } else {
        WatchLoginView(viewModel: authViewModel)
      }
    }
    .overlay(alignment: .top) {
      if !connectivity.isOnline {
        Badge(kind: .offline)
          .padding(.top, 2)
        .transition(.opacity)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // Like the system Now Playing app: coming back to the watch while music
      // plays shows the player. A short glance away keeps the browsing place.
      // Lowering the wrist only makes the scene inactive and does not count.
      if phase == .background {
        if leftAt == nil { leftAt = Date() }
      } else if phase == .active, let leftAt {
        self.leftAt = nil
        if playerViewModel.isPlaying, selectedTab != .nowPlaying,
          Date().timeIntervalSince(leftAt) > 8
        {
          showPlayer()
        }
      }
    }
    .onChange(of: playerViewModel.hasNowPlaying()) { _, hasNowPlaying in
      if !hasNowPlaying { selectedTab = .home }
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
    .environmentObject(downloadViewModel)
    #if DEBUG
      .task { await runDebugDownloadActions() }
      .task { await runDebugSyncActions() }
      .task { await runDebugHistoryActions() }
      .task { await runDebugKeepPlaying() }
      .task { await runDebugRatingUI() }
      .task { await runDebugMixDump() }
      .task { await runDebugDiagnostics() }
      .sheet(isPresented: $showsDebugDiagnostics) { NavigationStack { WatchDiagnosticsView() } }
      .task { await runDebugScreen() }
      .sheet(item: $debugLoginScreen) { $0.view }
    #endif
  }
}

#if DEBUG
  private struct DebugScreen: Identifiable, Hashable {
    let id = UUID()
    let view: AnyView

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

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

      for _ in 0..<120 where downloadViewModel.isDownloading(collectionId: album.id) {
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

    // FLO_DEBUG_SYNC=1|force syncs the song library and logs what it cached.
    fileprivate func runDebugSyncActions() async {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_SYNC"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      let songs = await SmartPlaybackService.shared.syncSongLibrary(force: value == "force")
      // The cache is written in the background.
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      let stamp = LibraryCacheManager.shared.load(LibraryStamp.self, forKey: "songs.stamp")
      debugLog("sync hook: \(songs.count) songs, stamp=\(String(describing: stamp))")
      debugLog("ratings: \(RatingStore.shared.ratings.count) \(RatingStore.shared.ratings)")
    }

    // FLO_DEBUG_HISTORY=1|rebuild imports the server's play log (after
    // throwing the mirror away for rebuild) and logs the import state, the
    // strongest artist and genre aggregates and the start of the share log.
    fileprivate func runDebugHistoryActions() async {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_HISTORY"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      let store = ListeningHistoryStore.shared
      if value == "rebuild" {
        await store.rebuild()
      } else {
        await store.refresh(reason: .debug)
      }

      let evaluatedAt = Date()
      let snapshot = await store.snapshot()
      let state = HistoryStatus.shared.state
      debugLog(
        "history state at \(String(format: "%.3f", evaluatedAt.timeIntervalSince1970)): phase=\(state.phase) pages=\(state.pages) total=\(state.serverTotal) "
          + "imported=\(state.importedCount) matched=\(state.matchedCount) "
          + "unmatched=\(state.unmatchedCount) watermark=\(state.watermarkId) "
          + "bootstrapComplete=\(state.bootstrapComplete) "
          + "earliest=\(state.earliestPlayAt.map { "\($0)" } ?? "-") future=\(snapshot.futurePlays)")
      debugLog("ratings: \(RatingStore.shared.ratings.count) \(RatingStore.shared.ratings)")
      for kind in [AffinitySnapshot.Kind.artist, .genre] {
        let top = (snapshot.aggregates[kind] ?? [:]).sorted { $0.value.weight > $1.value.weight }
        for (key, aggregate) in top.prefix(5) {
          debugLog(
            "  \(kind) \(key) weight=\(String(format: "%.9f", aggregate.weight)) "
              + "plays=\(aggregate.plays)")
        }
      }

      let export = WatchDiagnosticsView.exportText()
      debugLog("share log: \(export.count) characters")
      for line in export.split(separator: "\n", omittingEmptySubsequences: false).prefix(10) {
        debugLog("  | \(line)")
      }
    }

    // FLO_DEBUG_KEEP_PLAYING=1 turns Keep Playing on and plays the first
    // cached song alone, seeked close to its end so the continuation follows
    // at once; =short plays the shortest one through, so it qualifies first.
    fileprivate func runDebugKeepPlaying() async {
      guard let mode = ProcessInfo.processInfo.environment["FLO_DEBUG_KEEP_PLAYING"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      UserDefaultsManager.keepPlaying = true
      let songs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
      let song =
        mode == "short"
        ? songs.filter { $0.duration > 0 }.min { $0.duration < $1.duration } : songs.first
      guard let song else { return debugLog("keep playing hook: no cached songs") }
      debugLog("keep playing hook: \(song.id) \(song.title) \(Int(song.duration))s")
      playerViewModel.playItem(
        item: SongCollection(id: "debug", name: "Debug", songs: [song]), isFromLocal: false)
      selectedTab = .nowPlaying
      guard mode != "short" else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      playerViewModel.seek(to: 0.97)
    }

    // FLO_DEBUG_RATE_UI=<0|1|5> rates the playing song the way the rating
    // dialog does, with the player shown.
    fileprivate func runDebugRatingUI() async {
      guard let rating = ProcessInfo.processInfo.environment["FLO_DEBUG_RATE_UI"].flatMap(Int.init)
      else { return }
      for _ in 0..<60 where !playerViewModel.isPlaying {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard playerViewModel.hasNowPlaying() else { return debugLog("rating hook: nothing playing") }
      selectedTab = .nowPlaying
      playerViewModel.rateNowPlaying(rating)
      debugLog("rating hook: \(playerViewModel.nowPlaying.id ?? "") rated \(rating)")
    }

    // FLO_DEBUG_DUMP_MIX=<s> logs the newest mix record at that time.
    fileprivate func runDebugMixDump() async {
      guard let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_DUMP_MIX"].flatMap(Double.init)
      else { return }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let mix = RecommendationLog.shared.mixes.first else {
        return debugLog("mix dump: no mix recorded")
      }
      debugLog(
        "mix dump: \(mix.mode) picks=\(mix.picks.count) eligible=\(mix.eligible) "
          + "explore=\(String(format: "%.2f", mix.exploreShare)) notes=\(mix.notes)")
      for pick in mix.picks {
        debugLog("  \(pick.slot) \(pick.title) — \(pick.artist) | \(pick.reason) | \(pick.scores)")
      }
    }

    // FLO_DEBUG_DIAGNOSTICS=<s> shows Diagnostics at that time and logs the
    // size of the shared log.
    fileprivate func runDebugDiagnostics() async {
      guard let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_DIAGNOSTICS"].flatMap(Double.init)
      else { return }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      showsDebugDiagnostics = true
      let export = WatchDiagnosticsView.exportText()
      debugLog(
        "diagnostics: share log \(export.count) characters, "
          + "last mixes=\(export.contains("\nLast mixes\n") || export.hasSuffix("\nLast mixes"))")
      let lines = export.split(separator: "\n", omittingEmptySubsequences: false)
      for line in lines where line.hasPrefix("Rated songs") { debugLog("  | \(line)") }
      for line in lines.drop(while: { $0 != "Last mixes" }) { debugLog("  | \(line)") }
    }

    // FLO_DEBUG_SCREEN=<name> pushes one screen four seconds after
    // launch, for screenshots: albums, album, playlist, artist, liked, radios,
    // downloads, settings, queue, login-error.
    fileprivate func runDebugScreen() async {
      guard let name = ProcessInfo.processInfo.environment["FLO_DEBUG_SCREEN"] else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)

      func load<T>(_ call: (@escaping (Result<[T], Error>) -> Void) -> Void) async -> [T] {
        await withCheckedContinuation { continuation in
          call { continuation.resume(returning: (try? $0.get()) ?? []) }
        }
      }

      let view: AnyView
      switch name {
      case "albums": view = AnyView(WatchAlbumsListView())
      case "album":
        guard let album = await load(AlbumService.shared.getAlbum).first else {
          return debugLog("screen hook: no albums")
        }
        view = AnyView(WatchAlbumDetailView(album: album))
      case "playlist":
        guard let playlist = await load(AlbumService.shared.getPlaylists).first else {
          return debugLog("screen hook: no playlists")
        }
        view = AnyView(WatchPlaylistDetailView(playlist: playlist))
      case "artist":
        // The artist with the most albums, so the album list has rows.
        guard let artist = await load(AlbumService.shared.getArtists).max(by: { $0.albumCount < $1.albumCount })
        else {
          return debugLog("screen hook: no artists")
        }
        view = AnyView(WatchArtistDetailView(artist: artist))
      case "liked": view = AnyView(WatchStarredSongsView())
      case "radios": view = AnyView(WatchRadiosView())
      case "downloads": view = AnyView(WatchDownloadsView())
      case "settings": view = AnyView(WatchSettingsView())
      case "queue": view = AnyView(WatchQueueView())
      case "login-error":
        let auth = AuthViewModel()
        auth.alertMessage = "Wrong username or password."
        auth.showAlert = true
        debugLoginScreen = DebugScreen(view: AnyView(WatchLoginView(viewModel: auth)))
        return debugLog("screen hook: showing \(name)")
      default: return debugLog("screen hook: unknown screen \(name)")
      }
      debugLog("screen hook: showing \(name)")
      debugScreen = DebugScreen(view: view)

      // FLO_DEBUG_SCREEN_PLAY=1 then plays the first album the way its Play
      // button does, to check that the pushed screen gives way to the player;
      // =<albumId>:<songId> plays that song of that album instead.
      guard let play = ProcessInfo.processInfo.environment["FLO_DEBUG_SCREEN_PLAY"],
        var album = await load(AlbumService.shared.getAlbum).first
      else { return }
      let target = play.split(separator: ":").map(String.init)
      if target.count == 2 { album.id = target[0] }
      album.songs = await load { AlbumService.shared.getSongFromAlbum(id: album.id, completion: $0) }
      let index = target.count == 2 ? album.songs.firstIndex { $0.playbackID == target[1] } ?? 0 : 0
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      // Library screens are links the reset drops; this one is hook state.
      debugScreen = nil
      if playerViewModel.playBySong(idx: index, item: album, isFromLocal: false) { showPlayer() }
      debugLog("screen hook: played \(album.songs.indices.contains(index) ? album.songs[index].title : "-"), page=\(selectedTab)")
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
