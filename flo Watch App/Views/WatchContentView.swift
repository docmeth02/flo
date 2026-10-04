//
//  WatchContentView.swift
//  flo Watch App
//

import SwiftUI

extension EnvironmentValues {
  /// Leaves the library for the player page; set by WatchContentView.
  @Entry var showPlayer: () -> Void = {}
  /// Selects the player page without popping, for the root of the stack,
  /// where a reset would only rebuild Home.
  @Entry var selectPlayerPage: () -> Void = {}
  /// Tells WatchContentView whether the queue is pushed over the player.
  @Entry var setQueueShown: (Bool) -> Void = { _ in }
}

struct WatchContentView: View {
  @StateObject private var authViewModel = AuthViewModel()
  @StateObject var playerViewModel = WatchPlayerViewModel()
  @StateObject var albumViewModel = AlbumViewModel()
  // Playback and scrobbling use the shared instance; Settings must show the
  // same state.
  @StateObject private var floooViewModel = FloooViewModel.shared
  @StateObject var downloadViewModel = DownloadViewModel()
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @Environment(\.scenePhase) private var scenePhase

  @State var selectedTab = Tab.home
  // Recreating the stack pops whatever was browsed on top of the tabs.
  @State private var stackID = UUID()
  @State private var leftAt: Date?
  @State private var leftTheApp = false
  @State private var queueShown = false
  // State of the launch hooks in Debug/WatchContentView+Debug.swift; they
  // also use the view models, selectedTab and showPlayer, so those are not
  // private.
  #if DEBUG
    @State var showsDebugDiagnostics = false
    @State var debugScreen: DebugScreen?
    @State var debugLoginScreen: DebugScreen?
  #endif

  enum Tab { case home, nowPlaying }

  /// Pops whatever was browsed and selects the player page, so there is only
  /// one player. The rebuilt page view starts on its first page; the player is
  /// selected once it is in place. Resetting first makes that a real change
  /// when the player was already selected.
  func showPlayer() {
    selectedTab = .home
    stackID = UUID()
    DispatchQueue.main.async { selectedTab = .nowPlaying }
  }

  /// Plays a mix for Siri, Shortcuts or the Action Button. Logged out, the
  /// request is dropped and the login screen stays.
  private func takePlaySomethingRequest() {
    guard PlaySomethingRequest.take(), authViewModel.isLoggedIn else { return }
    Task { if await playerViewModel.playSomething() { showPlayer() } }
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
        .environment(\.setQueueShown) { queueShown = $0 }
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
      if phase != .active {
        AuthService.shared.persistRenewedToken()
        if leftAt == nil { leftAt = Date() }
        if phase == .background { leftTheApp = true }
      } else if let leftAt {
        self.leftAt = nil
        let leftTheApp = self.leftTheApp
        self.leftTheApp = false
        // The player page shown as it is stays, or its backdrops re-decode;
        // back from another app, a queue pushed on top of it gives way.
        if playerViewModel.isPlaying, Date().timeIntervalSince(leftAt) > 8,
          selectedTab != .nowPlaying || (leftTheApp && queueShown)
        {
          showPlayer()
        }
      }
    }
    .onChange(of: playerViewModel.hasNowPlaying()) { _, hasNowPlaying in
      if !hasNowPlaying { selectedTab = .home }
    }
    .onAppear(perform: takePlaySomethingRequest)
    .onReceive(NotificationCenter.default.publisher(for: .playSomethingRequested)) { _ in
      takePlaySomethingRequest()
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(floooViewModel)
    .environmentObject(downloadViewModel)
    .environmentObject(PinStore.shared)
    #if DEBUG
      .task { await runDebugLaunchActions() }
      .sheet(isPresented: $showsDebugDiagnostics) { NavigationStack { WatchDiagnosticsView() } }
      .sheet(item: $debugLoginScreen) { $0.view }
    #endif
  }
}

