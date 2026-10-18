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
    .environmentObject(app.downloads)
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
  enum TabID { case home, library, search }

  @EnvironmentObject var app: AppModel
  @Environment(\.palette) private var palette
  // Not private: the debug launch hook selects a tab and pushes onto it.
  @State var tab = TabID.home
  @State var paths: [TabID: NavigationPath] = [:]
  @SceneStorage("libraryChip") private var libraryChip = LibraryChip.albums

  var body: some View {
    TabView(selection: $tab) {
      Tab("Home", systemImage: "house", value: .home) {
        stack(.home) { HomeView() }
      }
      Tab("Library", systemImage: "books.vertical", value: .library) {
        stack(.library) { LibraryView(chip: $libraryChip) }
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
    .fullScreenCover(isPresented: $app.isNowPlayingPresented) {
      NowPlayingView()
    }
    #if DEBUG
      .task { await runDebugScreen() }
    #endif
  }

  /// iOS 27 draws a search role tab inside the bar; the prominent role keeps
  /// the design's round button beside it, and SearchView brings its own field.
  private static var searchRole: TabRole {
    if #available(iOS 27, *) { .prominent } else { .search }
  }

  private func stack(_ id: TabID, @ViewBuilder _ root: () -> some View) -> some View {
    NavigationStack(path: Binding { paths[id] ?? NavigationPath() } set: { paths[id] = $0 }) {
      root()
        .containerBackground(palette.background, for: .navigation)
        .navigationDestination(for: Route.self) { route in
          Group {
            switch route {
            case .album(let album): AlbumView(album: album)
            case .artist(let artist): ArtistView(artist: artist)
            case .playlist(let playlist): PlaylistView(playlist: playlist)
            case .settings: SettingsView()
            }
          }
          .containerBackground(palette.background, for: .navigation)
        }
    }
  }
}
