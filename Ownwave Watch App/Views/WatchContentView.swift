//
//  WatchContentView.swift
//  Ownwave Watch App
//

import SwiftUI

extension EnvironmentValues {
  /// Leaves the library for the player page; set by WatchContentView.
  @Entry var showPlayer = EnvironmentAction<Void> {}
  /// Selects the player page without popping, for the root of the stack,
  /// where a reset would only rebuild Home.
  @Entry var selectPlayerPage = EnvironmentAction<Void> {}
  /// Tells WatchContentView whether the queue is pushed over the player.
  @Entry var setQueueShown = EnvironmentAction<Bool> { _ in }
}

struct WatchContentView: View {
  @StateObject private var authViewModel = AuthViewModel()
  @StateObject var playerViewModel = PlayerViewModel()
  @StateObject var albumViewModel = AlbumViewModel()
  /// The stations for Home and Radios, kept when `showPlayer()` rebuilds the
  /// stack, so a play action asks for none.
  @StateObject private var radios = RadiosViewModel()
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @ObservedObject private var phone = PhoneLink.shared
  @Environment(\.scenePhase) private var scenePhase

  @State var selectedTab = Tab.home
  // Recreating the stack pops whatever was browsed on top of the tabs.
  @State private var stackID = UUID()
  @State private var leftAt: Date?
  @State private var leftTheApp = false
  @State private var queueShown = false
  // The login running now uses the iPhone's credentials.
  @State private var runsPhoneSignIn = false
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

  /// Signs in with the credentials the iPhone sent; only this attempt's
  /// outcome goes back to the phone.
  private func runPhoneSignIn(_ request: Link.SignIn) {
    // Signed in meanwhile, or with a Keychain that would not read: the
    // watch keeps its login, and its state tells the phone; signed in to
    // another account, the phone hears why, as it would have at once.
    guard !authViewModel.isLoggedIn else {
      guard AuthService.shared.accountKey != request.accountKey else {
        return phone.signInFinished(error: nil)
      }
      let account = PhoneLinkReceiver.signedInAccount()
      return phone.signInFinished(
        error: Link.otherAccountMessage(user: account?.user ?? "", host: account?.host ?? ""))
    }
    authViewModel.serverUrl = request.server
    authViewModel.username = request.user
    authViewModel.password = request.password
    runsPhoneSignIn = true
    authViewModel.login()
  }

  /// Plays what Siri, Shortcuts or the Action Button asked for. Logged out,
  /// the request is dropped and the login screen stays.
  private func takePlayRequest() {
    guard let request = PlayRequest.take(), authViewModel.isLoggedIn else { return }
    Task {
      let played =
        switch request {
        case .something: await playerViewModel.playSomething()
        case .artist(let id, let name): await playerViewModel.playArtist(id: id, name: name)
        }
      if played { showPlayer() }
    }
  }

  var body: some View {
    Group {
      if authViewModel.isLoggedIn {
        NavigationStack {
          TabView(selection: $selectedTab) {
            WatchHomeView()
              .tag(Tab.home)

            if playerViewModel.nowPlaying != nil {
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
        .environment(\.showPlayer, EnvironmentAction { showPlayer() })
        .environment(\.selectPlayerPage, EnvironmentAction { selectedTab = .nowPlaying })
        .environment(\.setQueueShown, EnvironmentAction { queueShown = $0 })
      } else {
        WatchLoginView(viewModel: authViewModel)
      }
    }
    // At the bottom, where it covers the least: the player's top holds the
    // title.
    .overlay(alignment: .bottom) {
      if !connectivity.isOnline {
        Badge(kind: .offline)
          .padding(.bottom, WatchLayout.offlineBadgeLift)
          .ignoresSafeArea(edges: .bottom)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // Whether a stall happened in the background shows in Diagnostics.
      RequestLog.shared.note("app \(phase)")
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
    .onChange(of: playerViewModel.nowPlaying != nil) { _, hasNowPlaying in
      if !hasNowPlaying { selectedTab = .home }
    }
    // The iPhone signs the watch in with the watch's own login. A request
    // arriving while the watch's own attempt runs waits for its end.
    .onChange(of: phone.signInRequest) { _, request in
      guard let request, !authViewModel.isSubmitting else { return }
      runPhoneSignIn(request)
    }
    .onChange(of: authViewModel.isSubmitting) { _, submitting in
      guard !submitting else { return }
      if runsPhoneSignIn {
        runsPhoneSignIn = false
        phone.signInFinished(
          error: authViewModel.isLoggedIn ? nil : authViewModel.loginError?.loginMessage)
      } else if let request = phone.signInRequest {
        runPhoneSignIn(request)
      }
    }
    .onChange(of: authViewModel.isLoggedIn) { phone.publishState() }
    // The queue sync follows the player this view owns.
    .onAppear { PlayQueueSync.shared.attach(playerViewModel) }
    // The next account must not see this one's stations.
    .onReceive(NotificationCenter.default.publisher(for: .didLogout)) { _ in radios.reset() }
    .onAppear(perform: takePlayRequest)
    .onReceive(NotificationCenter.default.publisher(for: .playRequested)) { _ in
      takePlayRequest()
    }
    .environmentObject(authViewModel)
    .environmentObject(playerViewModel)
    .environmentObject(albumViewModel)
    .environmentObject(radios)
    .environmentObject(DownloadSession.shared)
    .environmentObject(PinStore.shared)
    #if DEBUG
      .task { await runDebugLaunchActions() }
      .sheet(isPresented: $showsDebugDiagnostics) { NavigationStack { WatchDiagnosticsView() } }
      .sheet(item: $debugLoginScreen) { $0.view }
    #endif
  }
}
