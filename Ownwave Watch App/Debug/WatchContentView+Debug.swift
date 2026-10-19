//
//  WatchContentView+Debug.swift
//  Ownwave Watch App
//

#if DEBUG
  import SwiftUI

  struct DebugScreen: Identifiable, Hashable {
    let id = UUID()
    let view: AnyView

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

  extension WatchContentView {
    /// Runs every launch hook side by side, as one `.task` each did.
    func runDebugLaunchActions() async {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await runDebugDownloadActions() }
        group.addTask { await runDebugBadDownload() }
        group.addTask { await runDebugSyncActions() }
        group.addTask { await runDebugHistoryActions() }
        group.addTask { await runDebugKeepPlaying() }
        group.addTask { await runDebugRatingUI() }
        group.addTask { await runDebugMixDump() }
        group.addTask { await runDebugDiagnostics() }
        group.addTask { await runDebugScreen() }
        group.addTask { await runDebugMenuActions() }
        group.addTask { await runDebugIntent() }
      }
    }

    // Simulator verification only. FLO_DEBUG_DOWNLOAD=album|playlist downloads
    // the smallest album or the first playlist of the library and logs the
    // files it produced; FLO_DEBUG_REMOVE=1 then removes it and logs what is
    // left.
    private func runDebugDownloadActions() async {
      let env = ProcessInfo.processInfo.environment
      guard let kind = env["FLO_DEBUG_DOWNLOAD"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)

      var album: Album
      if kind == "playlist" {
        let playlists = (try? await LibraryAPI.getPlaylists()) ?? []
        guard var first = playlists.first else { return debugLog("no playlists") }
        first.songs = (try? await LibraryAPI.getSongsByPlaylist(id: first.id)) ?? []
        album = Album(from: first)
        DownloadSession.shared.enqueue(first)
      } else {
        let albums: [Album]
        do {
          albums = try await LibraryAPI.getAlbum()
        } catch {
          debugLog("albums failed: \(error)")
          albums = []
        }
        var smallest: Album?
        for candidate in albums.prefix(10) {
          var loaded = candidate
          loaded.songs = (try? await LibraryAPI.getSongFromAlbum(id: candidate.id)) ?? []
          if !loaded.songs.isEmpty, loaded.songs.count < (smallest?.songs.count ?? .max) {
            smallest = loaded
          }
        }
        guard let smallest else { return debugLog("no albums") }
        album = smallest
        DownloadSession.shared.enqueue(album)
      }

      debugLog("downloading \(kind) \(album.id) with \(album.songs.count) songs")

      for _ in 0..<120 where DownloadSession.shared.isDownloading(collectionId: album.id) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      logMediaFiles("after download")

      guard env["FLO_DEBUG_REMOVE"] == "1" else { return }
      albumViewModel.removeDownload(id: album.id)
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      logMediaFiles("after removal")
    }

    // FLO_DEBUG_DOWNLOAD_BADID=1 queues a song with a media id the server
    // does not know into a made-up collection and logs whether it failed for
    // good (the red X) once its retries are spent, after about 8 minutes.
    private func runDebugBadDownload() async {
      guard ProcessInfo.processInfo.environment["FLO_DEBUG_DOWNLOAD_BADID"] == "1" else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      let song = Song(
        id: "flo-debug-missing", title: "Missing", albumId: "flo-debug-badid",
        albumName: "Bad id", artist: "flo", trackNumber: 1, discNumber: 1, bitRate: 0,
        sampleRate: 0, suffix: "mp3", duration: 0, mediaFileId: "flo-debug-missing")
      let album = Album(id: "flo-debug-badid", name: "Bad id", songs: [song])
      debugLog("bad id download: queued")
      DownloadSession.shared.enqueue(album)
      for _ in 0..<600 where DownloadSession.shared.isDownloading(collectionId: album.id) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      let failed = DownloadSession.shared.hasFailed(collectionId: album.id)
      debugLog("bad id download: failed=\(failed)")
    }

    // FLO_DEBUG_SYNC=1|force syncs the song library and logs what it cached.
    private func runDebugSyncActions() async {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_SYNC"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      let songs = await SmartPlaybackService.shared.syncSongLibrary(force: value == "force")
      // The cache is written in the background.
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      let stamp = LibraryCacheManager.shared.load(LibraryStamp.self, forKey: .songsStamp)
      debugLog("sync hook: \(songs.count) songs, stamp=\(String(describing: stamp))")
      debugLog("ratings: \(RatingStore.shared.ratings.count) \(RatingStore.shared.ratings)")
    }

    // FLO_DEBUG_HISTORY=1|rebuild imports the server's play log (after
    // throwing the mirror away for rebuild) and logs the import state, the
    // strongest artist and genre aggregates and the start of the share log.
    private func runDebugHistoryActions() async {
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
          + "earliest=\(state.earliestPlayAt.map { "\($0)" } ?? "-") future=\(snapshot.futurePlays)"
      )
      debugLog("ratings: \(RatingStore.shared.ratings.count) \(RatingStore.shared.ratings)")
      for kind in [AffinitySnapshot.Kind.artist, .genre] {
        let top = (snapshot.aggregates[kind] ?? [:]).sorted { $0.value.weight > $1.value.weight }
        for (key, aggregate) in top.prefix(5) {
          debugLog(
            "  \(kind) \(key) weight=\(String(format: "%.9f", aggregate.weight)) "
              + "plays=\(aggregate.plays)")
        }
      }

      let export = DiagnosticsReport.text()
      debugLog("share log: \(export.count) characters")
      for line in export.split(separator: "\n", omittingEmptySubsequences: false).prefix(10) {
        debugLog("  | \(line)")
      }
    }

    // FLO_DEBUG_KEEP_PLAYING=1 turns Keep Playing on and plays the first
    // cached song alone, seeked close to its end so the continuation follows
    // at once; =short plays the shortest one through, so it qualifies first.
    private func runDebugKeepPlaying() async {
      guard let mode = ProcessInfo.processInfo.environment["FLO_DEBUG_KEEP_PLAYING"] else { return }
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      UserDefaultsManager.keepPlaying = true
      let songs = LibraryCacheManager.shared.load([Song].self, forKey: .songs) ?? []
      let song =
        mode == "short"
        ? songs.filter { $0.duration > 0 }.min { $0.duration < $1.duration } : songs.first
      guard let song else { return debugLog("keep playing hook: no cached songs") }
      debugLog("keep playing hook: \(song.id) \(song.title) \(Int(song.duration))s")
      playerViewModel.playItem(item: SongCollection(id: "debug", name: "Debug", songs: [song]))
      selectedTab = .nowPlaying
      guard mode != "short" else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      playerViewModel.seek(to: 0.97)
    }

    // FLO_DEBUG_RATE_UI=<0|1|5> rates the playing song the way the rating
    // dialog does, with the player shown.
    private func runDebugRatingUI() async {
      guard let rating = ProcessInfo.processInfo.environment["FLO_DEBUG_RATE_UI"].flatMap(Int.init)
      else { return }
      for _ in 0..<60 where !playerViewModel.isPlaying {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard let song = playerViewModel.nowPlaying else { return debugLog("rating hook: nothing playing") }
      selectedTab = .nowPlaying
      playerViewModel.rateNowPlaying(rating)
      debugLog("rating hook: \(song.id ?? "") rated \(rating)")
    }

    // FLO_DEBUG_DUMP_MIX=<s> logs the newest mix record at that time.
    private func runDebugMixDump() async {
      guard
        let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_DUMP_MIX"].flatMap(Double.init)
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
    private func runDebugDiagnostics() async {
      guard
        let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_DIAGNOSTICS"].flatMap(
          Double.init)
      else { return }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      showsDebugDiagnostics = true
      let export = DiagnosticsReport.text()
      debugLog(
        "diagnostics: share log \(export.count) characters, "
          + "last mixes=\(export.contains("\nLast mixes\n") || export.hasSuffix("\nLast mixes"))")
      let lines = export.split(separator: "\n", omittingEmptySubsequences: false)
      for line in lines where line.hasPrefix("Rated songs") { debugLog("  | \(line)") }
      for line in lines.drop(while: { $0 != "Last mixes" }) { debugLog("  | \(line)") }
    }

    // FLO_DEBUG_INTENT=1 asks for Play Something the way the App Intent does,
    // three seconds after launch; FLO_DEBUG_INTENT=artist:<name> asks for the
    // artist Siri would resolve that name to; FLO_DEBUG_INTENT=like:song and
    // the like logs the answer to an edit of what is playing.
    private func runDebugIntent() async {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_INTENT"] else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if value == "1" {
        debugLog("intent hook: requesting play something")
        PlayRequest.post(.something)
      } else if value.hasPrefix("artist:") {
        let name = String(value.dropFirst("artist:".count))
        guard let artist = try? await ArtistAppEntity.defaultQuery.entities(matching: name).first
        else {
          debugLog("intent hook: no cached artist matches \(name)")
          return
        }
        debugLog("intent hook: requesting artist \(artist.name) (\(artist.id))")
        PlayRequest.post(.artist(id: artist.id, name: artist.name))
      } else {
        // Commands separated by commas, once something plays (at most 30 s).
        for _ in 0..<30 where NowPlayingTarget.current == nil {
          try? await Task.sleep(for: .seconds(1))
        }
        for command in value.split(separator: ",").map(String.init) {
          let reply = await Self.debugEditReply(command)
          debugLog("intent hook: \(command) says \(reply ?? "nothing, unknown command")")
        }
      }
    }

    // like:|unlike:song|album|artist and boost:|avoid:song|artist answer the
    // way Siri would for what is playing.
    @MainActor private static func debugEditReply(_ value: String) async -> String? {
      let parts = value.split(separator: ":").map(String.init)
      guard parts.count == 2 else { return nil }
      switch (parts[0], LikeTarget(rawValue: parts[1]), RateTarget(rawValue: parts[1])) {
      case ("like", let target?, _):
        let intent = LikeIntent()
        intent.target = target
        return await intent.reply()
      case ("unlike", let target?, _):
        let intent = UnlikeIntent()
        intent.target = target
        return await intent.reply()
      case ("boost", _, let target?):
        let intent = BoostIntent()
        intent.target = target
        return await intent.reply()
      case ("avoid", _, let target?):
        let intent = AvoidIntent()
        intent.target = target
        return await intent.reply()
      default:
        return nil
      }
    }

    // FLO_DEBUG_SCREEN=<name> pushes one screen four seconds after
    // launch, for screenshots: albums, artists, album, playlist, artist, liked, radios,
    // downloads, settings, queue, search (FLO_DEBUG_SEARCH=<query> fills in
    // the query), login-error.
    private func runDebugScreen() async {
      guard let name = ProcessInfo.processInfo.environment["FLO_DEBUG_SCREEN"] else { return }
      try? await Task.sleep(nanoseconds: 4_000_000_000)

      let view: AnyView
      switch name {
      case "albums": view = AnyView(WatchAlbumsListView())
      case "artists": view = AnyView(WatchArtistsListView())
      case "album":
        guard let album = try? await LibraryAPI.getAlbum().first else {
          return debugLog("screen hook: no albums")
        }
        view = AnyView(WatchAlbumDetailView(album: album))
      case "playlist":
        guard let playlist = try? await LibraryAPI.getPlaylists().first else {
          return debugLog("screen hook: no playlists")
        }
        view = AnyView(WatchPlaylistDetailView(playlist: playlist))
      case "artist":
        // The artist with the most albums, so the album list has rows.
        guard
          let artist = try? await LibraryAPI.getArtists().max(by: {
            $0.albumCount < $1.albumCount
          })
        else {
          return debugLog("screen hook: no artists")
        }
        view = AnyView(WatchArtistDetailView(artist: artist))
      case "liked": view = AnyView(WatchLikedView())
      case "radios": view = AnyView(WatchRadiosView())
      case "downloads": view = AnyView(WatchDownloadsView())
      case "settings": view = AnyView(WatchSettingsView())
      case "queue": view = AnyView(WatchQueueView())
      case "search":
        view = AnyView(
          WatchSearchView(query: ProcessInfo.processInfo.environment["FLO_DEBUG_SEARCH"] ?? ""))
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
        var album = try? await LibraryAPI.getAlbum().first
      else { return }
      let target = play.split(separator: ":").map(String.init)
      if target.count == 2 { album.id = target[0] }
      album.songs = (try? await LibraryAPI.getSongFromAlbum(id: album.id)) ?? []
      let index = target.count == 2 ? album.songs.firstIndex { $0.playbackID == target[1] } ?? 0 : 0
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      // Library screens are links the reset drops; this one is hook state.
      debugScreen = nil
      if playerViewModel.playItem(item: album, startingAt: index) { showPlayer() }
      debugLog(
        "screen hook: played \(album.songs.indices.contains(index) ? album.songs[index].title : "-"), page=\(selectedTab)"
      )
    }

    private func logMediaFiles(_ label: String) {
      let media = LocalFileManager.shared.fileURL(for: "Media")
      let files =
        FileManager.default.enumerator(atPath: media.path)?
        .compactMap { $0 as? String } ?? []
      let songs = CoreDataManager.shared.countRecords(entity: SongEntity.self)
      let collections = CoreDataManager.shared.countRecords(entity: PlaylistEntity.self)
      debugLog("\(label): songs=\(songs) collections=\(collections) files=\(files.sorted())")
    }
  }
#endif
