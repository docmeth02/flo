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

    /// Two albums on the watch and one on its way, from the cached library.
    private func showDemo(signedIn: Bool) {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        let albums = AppModel.shared.albums.albums
        var state = Link.WatchState()
        if signedIn, let key = AuthService.shared.accountKey {
          state.account = .init(
            user: "demo", host: URL(string: UserDefaultsManager.serverBaseURL)?.host ?? "", key: key
          )
        }
        state.collections = albums.prefix(2).map {
          .init(id: $0.id, name: $0.name, songs: 11, kbps: 192)
        }
        state.musicBytes = 1_400_000_000
        state.freeBytes = 18_300_000_000
        let sends = albums.dropFirst(2).prefix(1).map { Send(album: $0, songs: 9, progress: 0.4) }
        showDemo(state, sends: Array(sends))
      }
    }
  }
#endif
