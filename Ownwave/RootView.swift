//
//  RootView.swift
//  Ownwave
//

import SwiftUI

/// The screens pushed onto a tab's stack.
enum Route: Hashable {
  case album(Album)
  case artist(Artist)
  case playlist(Playlist)
  case settings
  case watch
}

extension EnvironmentValues {
  /// Switches to the Library tab on one of its chips (Home's See all).
  @Entry var openLibrary: (LibraryChip) -> Void = { _ in }
}

/// The app's look: follows the system, or stays dark or light (Settings).
enum Appearance: String, CaseIterable {
  case system, dark, light

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .dark: .dark
    case .light: .light
    }
  }
}

struct RootView: View {
  @ObservedObject private var app = AppModel.shared
  @ObservedObject private var auth = AppModel.shared.auth
  @AppStorage("appearance") private var appearance = Appearance.system
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Themed {
      if auth.isLoggedIn {
        AppTabs()
      } else {
        LoginView()
      }
    }
    .preferredColorScheme(appearance.colorScheme)
    .onChange(of: scenePhase) { _, phase in
      RequestLog.shared.note("app \(phase)")
      if phase != .active { AuthService.shared.persistRenewedToken() }
    }
    .onAppear { app.takePlayRequest() }
    .onReceive(NotificationCenter.default.publisher(for: .playRequested)) { _ in
      app.takePlayRequest()
    }
    .environmentObject(app)
    .environmentObject(app.auth)
    .environmentObject(app.player)
    .environmentObject(app.albums)
    .environmentObject(DownloadSession.shared)
    .environmentObject(FloooViewModel.shared)
    .environmentObject(PinStore.shared)
  }
}

/// Hands the palette of the color scheme in use to everything below.
private struct Themed<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let palette = scheme == .dark ? Palette.dark : Palette.light
    content
      .environment(\.palette, palette)
      .tint(palette.accent)
      .foregroundStyle(palette.text)
  }
}

struct AppTabs: View {
  enum TabID { case home, library, taste, search }

  @EnvironmentObject var app: AppModel
  @Environment(\.palette) private var palette
  // Not private: the debug launch hook selects a tab and pushes onto it.
  @State var tab = TabID.home
  @State var paths: [TabID: NavigationPath] = [:]
  @SceneStorage("libraryChip") private var libraryChip = LibraryChip.albums
  @AppStorage("tourSeen") private var tourSeen = false

  var body: some View {
    TabView(selection: $tab) {
      Tab("Home", systemImage: "house", value: .home) {
        stack(.home) { HomeView() }
      }
      Tab("Library", systemImage: "books.vertical", value: .library) {
        stack(.library) { LibraryView(chip: $libraryChip) }
      }
      Tab("Taste", systemImage: "slider.horizontal.3", value: .taste) {
        stack(.taste) { TasteView() }
      }
      Tab("Search", systemImage: "magnifyingglass", value: .search, role: Self.searchRole) {
        stack(.search) { SearchView() }
      }
    }
    .environment(\.openLibrary) { chip in
      libraryChip = chip
      paths[.library] = nil
      tab = .library
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .tabViewBottomAccessory { MiniPlayer() }
    .toastOverlay(app.toast, bottom: 140)
    .tourOverlay(tourStep)
    .fullScreenCover(isPresented: $app.isNowPlayingPresented) {
      NowPlayingView()
    }
    .onOpenURL(perform: open)
    .onChange(of: app.tour) { follow($1) }
    .task { await startTourOnce() }
    #if DEBUG
      .task { await runDebugScreen() }
    #endif
  }

  /// The widgets' links: `ownwave://nowplaying`, `ownwave://album/<id>`, and
  /// `ownwave://`, which only brings the app forward.
  private func open(_ url: URL) {
    guard url.scheme == "ownwave" else { return }
    switch url.host() {
    case "nowplaying":
      if app.player.nowPlaying != nil { app.isNowPlayingPresented = true }
    case "album":
      let id = url.lastPathComponent
      Task {
        let albums: [Album] = await app.albums.loadedOrCached(app.albums.albums, .albums)
        guard
          let album = app.albums.recentAlbums.first(where: { $0.id == id })
            ?? albums.first(where: { $0.id == id })
        else { return }
        app.isNowPlayingPresented = false
        tab = .home
        paths[.home, default: NavigationPath()].append(Route.album(album))
      }
    default: break
    }
  }

  /// The tour's step shown over the tabs; open Now Playing shows its own.
  private var tourStep: TourStep? {
    guard let step = app.tour, !(step.isOnNowPlaying && app.isNowPlayingPresented) else {
      return nil
    }
    return step
  }

  /// The tour starts once, shortly after the tabs first show.
  private func startTourOnce() async {
    var step = tourSeen ? nil : TourStep.play
    #if DEBUG
      step = await debugTourStep() ?? step
    #endif
    guard let step, app.tour == nil else { return }
    // The tabs went away meanwhile (a logout): no tour over the login.
    do { try await Task.sleep(for: .seconds(0.7)) } catch { return }
    app.tour = step
  }

  /// Takes the tour to its step's screen; its end returns to Home.
  private func follow(_ step: TourStep?) {
    switch step {
    case .rate?, .why?, .peek?:
      // With nothing queued Now Playing closes itself, and the card stays
      // on the tabs.
      if app.player.nowPlaying != nil { app.isNowPlayingPresented = true }
      return
    case .play?: show(.home)
    case .taste?: show(.taste)
    case .send?: show(.home, Route.watch)
    case nil:
      // A logout ends the tour without it counting as seen.
      if app.auth.isLoggedIn { tourSeen = true }
      show(.home)
    }
    app.isNowPlayingPresented = false
  }

  /// Selects the tab `id` with only `routes` on its stack.
  private func show(_ id: TabID, _ routes: Route...) {
    tab = id
    paths[id] = NavigationPath(routes)
  }

  /// iOS 27 draws a search role tab inside the bar; the prominent role keeps
  /// the design's round button beside it, and SearchView brings its own field.
  private static var searchRole: TabRole {
    if #available(iOS 27, *) { .prominent } else { .search }
  }

  private func stack(_ id: TabID, @ViewBuilder _ root: () -> some View) -> some View {
    NavigationStack(
      path: Binding {
        paths[id] ?? NavigationPath()
      } set: {
        paths[id] = $0
      }
    ) {
      root()
        .containerBackground(palette.background, for: .navigation)
        .navigationDestination(for: Route.self) { route in
          Group {
            switch route {
            case .album(let album): AlbumView(album: album)
            case .artist(let artist): ArtistView(artist: artist)
            case .playlist(let playlist): PlaylistView(playlist: playlist)
            case .settings: SettingsView()
            case .watch: WatchView()
            }
          }
          .containerBackground(palette.background, for: .navigation)
        }
    }
  }
}
