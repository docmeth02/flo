//
//  CarPlay+Debug.swift
//  Ownwave
//

#if DEBUG
  import CarPlay

  // Simulator verification only. FLO_DEBUG_CARPLAY=album|artist|playlist|
  // upnext|cached|rate|signedout|cellular opens that list on the car's screen
  // (album, artist and playlist: the first of each, or the one named by
  // FLO_DEBUG_SCREEN_ID) or presents that sheet, since the simulator can
  // neither tap the car's screen nor leave Wi-Fi.
  extension CarPlayController {
    func runDebugCarPlay() {
      let env = ProcessInfo.processInfo.environment
      guard let screen = env["FLO_DEBUG_CARPLAY"] else { return }
      let id = env["FLO_DEBUG_SCREEN_ID"]
      func pick<T: Identifiable>(_ items: [T]) -> T? where T.ID == String {
        id.flatMap { id in items.first { $0.id == id } } ?? items.first
      }
      Task {
        try? await Task.sleep(for: .seconds(3))
        switch screen {
        case "album":
          if let album = pick((try? await LibraryAPI.getAlbum()) ?? []) { openAlbum(album) }
        case "artist":
          if let artist = pick((try? await LibraryAPI.getArtists()) ?? []) { openArtist(artist) }
        case "playlist":
          if let playlist = pick((try? await LibraryAPI.getPlaylists()) ?? []) {
            openPlaylist(playlist)
          }
        case "upnext": openUpNext()
        case "cached": openCached()
        case "rate": presentRate()
        case "signedout": presentSignedOut()
        case "cellular": presentStreamingBlocked()
        default: break
        }
        debugLog("carplay hook: \(screen)")
      }
    }
  }
#endif
