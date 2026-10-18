//
//  WatchLink+Debug.swift
//  Ownwave
//

#if DEBUG
  import Foundation

  // Simulator verification only. FLO_DEBUG_WATCH=signin signs the watch in a
  // few seconds after launch; FLO_DEBUG_WATCH=send:<albumId> sends that album.
  extension WatchLink {
    func runDebugLaunchActions() {
      guard let action = ProcessInfo.processInfo.environment["FLO_DEBUG_WATCH"] else { return }
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
  }
#endif
