//
//  AppTabs+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_SCREEN=home|library|taste|search|
  // settings|server|watch|watchalbums|recent|album|artist|playlist|nowplaying|
  // widgets|login-error opens that screen
  // once the library answered (album, artist and playlist: the first of each,
  // or the one named by FLO_DEBUG_SCREEN_ID), for screenshots.
  extension AppTabs {
    // FLO_DEBUG_INTENT=1 runs the Play Something intent three seconds after
    // launch, FLO_DEBUG_INTENT=artist:<name> the Play Artist intent for the
    // artist Siri would resolve that name to; both log what Siri would get.
    func runDebugIntent() async {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_INTENT"] else { return }
      try? await Task.sleep(for: .seconds(3))
      do {
        if value.hasPrefix("artist:") {
          let name = String(value.dropFirst("artist:".count))
          guard let artist = try await ArtistAppEntity.defaultQuery.entities(matching: name).first
          else { return debugLog("intent hook: no cached artist matches \(name)") }
          let intent = PlayArtistIntent()
          intent.artist = artist
          _ = try await intent.perform()
        } else {
          _ = try await PlaySomethingIntent().perform()
        }
        debugLog(
          "intent hook: played \(AppModel.shared.player.nowPlaying?.songName ?? "-"), "
            + "now playing shown \(AppModel.shared.isNowPlayingPresented)")
      } catch let failure as PlayFailure {
        debugLog("intent hook: says \(String(localized: failure.localizedStringResource))")
      } catch {
        debugLog("intent hook: failed \(error)")
      }
    }

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
      case "taste": tab = .taste
      case "search": tab = .search
      case "settings": paths[.home, default: NavigationPath()].append(Route.settings)
      case "server": paths[.home, default: NavigationPath()].append(Route.server)
      case "recent": paths[.home, default: NavigationPath()].append(Route.recent)
      case "watchalbums": paths[.home, default: NavigationPath()].append(Route.watchAlbums)
      case "watch":
        // FLO_DEBUG_WATCH=demo takes its albums from the list a second later.
        let albums = app.albums
        albums.albums = await albums.loadedOrCached(albums.albums, .albums)
        paths[.home, default: NavigationPath()].append(Route.watch)
      case "album":
        let albums: [Album] = (try? await LibraryAPI.getAlbum()) ?? []
        if let album = pick(albums) {
          paths[.home, default: NavigationPath()].append(Route.album(album))
        }
      case "artist":
        let artists: [Artist] = (try? await LibraryAPI.getArtists()) ?? []
        if let artist = pick(artists) {
          paths[.home, default: NavigationPath()].append(Route.artist(artist))
        }
      case "playlist":
        let playlists: [Playlist] = (try? await LibraryAPI.getPlaylists()) ?? []
        if let playlist = pick(playlists) {
          paths[.home, default: NavigationPath()].append(Route.playlist(playlist))
        }
      case "nowplaying": app.isNowPlayingPresented = true
      case "widgets": WidgetGallery.present()
      case "login-error": presentLoginError()
      default: break
      }
      debugLog("screen hook: \(screen)")
    }

    /// The sign-in screen as a rejected sign-in leaves it, over the signed-in
    /// app, so the simulator keeps its login.
    private func presentLoginError() {
      let auth = AuthViewModel()
      auth.serverUrl = "https://music.example.com"
      auth.username = "anna"
      auth.password = "password"
      auth.loginError = .invalidCredentials(message: "")
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      guard var top = scene?.keyWindow?.rootViewController else { return }
      while let presented = top.presentedViewController { top = presented }
      let palette = top.traitCollection.userInterfaceStyle == .dark ? Palette.dark : Palette.light
      let host = UIHostingController(
        rootView: LoginView()
          .environmentObject(auth)
          .environment(\.palette, palette)
          .tint(palette.accent)
          .foregroundStyle(palette.text))
      host.modalPresentationStyle = .fullScreen
      top.present(host, animated: false)
    }
  }
#endif
