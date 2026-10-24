//
//  WatchLink+Debug.swift
//  Ownwave
//

#if DEBUG
  import Foundation

  // Simulator verification only. FLO_DEBUG_WATCH=signin signs the watch in a
  // few seconds after launch; FLO_DEBUG_WATCH=send:<albumId> sends that album;
  // FLO_DEBUG_WATCH=demo|demo-signedout shows a made-up watch for screenshots;
  // demo-send:<albumId> sends that album to the made-up watch, which runs the
  // outbox downloads and the cover, with nothing handed over.
  extension WatchLink {
    func runDebugLaunchActions() {
      guard let action = ProcessInfo.processInfo.environment["FLO_DEBUG_WATCH"] else { return }
      if action.hasPrefix("demo-send:") {
        showDemo(signedIn: true)
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(5))
          var album = Album()
          album.id = String(action.dropFirst(10))
          album.name = album.id
          send(album)
          for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(2))
            debugLog(
              "watch send: sends=\(sends.map { "\($0.id) \($0.songs) \(Int($0.progress * 100))%" }) "
                + "pending=\(WatchSend.shared.pending(album.id))")
          }
        }
        return
      }
      if action.hasPrefix("demo") { return showDemo(signedIn: action == "demo") }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        debugLog(
          "watch link: paired=\(isPaired) installed=\(isAppInstalled) reachable=\(isReachable) "
            + "watch=\(String(describing: watch?.account))")
        if action == "signin" {
          signInWatch()
        } else if action.hasPrefix("send:") {
          var album = Album()
          album.id = String(action.dropFirst(5))
          album.name = AppModel.shared.albums.albums.first { $0.id == album.id }?.name ?? album.id
          send(album)
        }
        for _ in 0..<60 {
          try? await Task.sleep(for: .seconds(2))
          debugLog(
            "watch link: signIn=\(signIn) sends=\(sends.map { "\($0.id) \(Int($0.progress * 100))%" }) "
              + "watch collections=\(watch?.collections.count ?? -1) "
              + "incoming=\(watch?.incoming ?? [:])")
        }
      }
    }

    /// Two albums on the watch, one it downloads itself and one on its way,
    /// from the cached library.
    private func showDemo(signedIn: Bool) {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        // The album list loads with the Library, which a debug screen skips.
        let library = AppModel.shared.albums
        if library.albums.isEmpty { library.fetchAlbums() }
        for _ in 0..<20 where library.albums.isEmpty {
          try? await Task.sleep(for: .milliseconds(500))
        }
        let albums = library.albums
        var state = Link.WatchState()
        if signedIn, let key = AuthService.shared.accountKey {
          state.account = .init(
            user: "demo", host: URL(string: UserDefaultsManager.serverBaseURL)?.host ?? "", key: key
          )
        }
        state.collections = albums.prefix(3).enumerated().map {
          .init(
            id: $1.id, name: $1.name, songs: 11, kbps: 192, downloading: $0 == 2 ? 4 : nil)
        }
        state.musicBytes = 1_400_000_000
        state.freeBytes = 18_300_000_000
        let sends = albums.dropFirst(3).prefix(1).map { Send(album: $0, songs: 9, progress: 0.4) }
        // The progress poll drops a send nothing is under way for, so the
        // made-up one is put back for a minute.
        for _ in 0..<60 {
          showDemo(state, sends: Array(sends))
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }
#endif
