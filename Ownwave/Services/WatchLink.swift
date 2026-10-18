//
//  WatchLink.swift
//  Ownwave
//

import WatchConnectivity

/// The iPhone's side of the link with the watch app: it signs the watch in,
/// shares the phone's settings, sends albums and shows what the watch holds.
@MainActor final class WatchLink: ObservableObject {
  static let shared = WatchLink()

  enum SignInPhase: Equatable {
    case idle, sending
    case failed(String)
  }

  /// An album on its way: downloaded here, then handed to the watch.
  struct Send: Identifiable {
    var id: String { album.id }
    let album: Album
    var songs: Int
    var progress = 0.0
  }

  @Published private(set) var isPaired = false
  @Published private(set) var isAppInstalled = false
  @Published private(set) var isReachable = false
  /// What the watch said last; it outlives a relaunch in the session.
  @Published private(set) var watch: Link.WatchState?
  @Published private(set) var signIn = SignInPhase.idle
  @Published private(set) var sends: [Send] = []

  private let session = WCSession.default
  private let receiver = Receiver()

  private init() {}

  func activate() {
    guard WCSession.isSupported() else { return }
    session.delegate = receiver
    session.activate()
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in WatchLink.shared.cancelSends() }
    }
    #if DEBUG
      runDebugLaunchActions()
    #endif
  }

  /// The watch is signed in to this phone's account.
  var isSignedIn: Bool {
    watch?.account?.key != nil && watch?.account?.key == AuthService.shared.accountKey
  }

  // MARK: - Sign-in

  /// Signs the watch in with this phone's server, user and saved password;
  /// the watch runs its own login with them.
  func signInWatch() {
    guard session.isReachable else {
      signIn = .failed("Open Ownwave on the watch, then try again.")
      return
    }
    guard case .found(let auth) = KeychainManager.loadAuth(),
      case .found(let password) = KeychainManager.loadPassword()
    else {
      signIn = .failed("This iPhone has no saved password to send.")
      return
    }
    signIn = .sending
    let request = Link.SignIn(
      server: UserDefaultsManager.serverBaseURL, user: auth.username, password: password)
    session.sendMessage(Link.encode(Link.Message.signIn(request))) { reply in
      let reply = Link.decode(Link.Reply.self, from: reply)
      Task { @MainActor in WatchLink.shared.answered(reply) }
    } errorHandler: { error in
      Task { @MainActor in WatchLink.shared.signIn = .failed(error.localizedDescription) }
    }
  }

  private func answered(_ reply: Link.Reply?) {
    switch reply {
    case .accepted: break
    case .alreadySignedIn: signIn = .idle
    case .otherAccount(let user, let host):
      signIn = .failed("The watch is signed in as \(user) on \(host). Log out there first.")
    case nil: signIn = .failed("The watch did not answer.")
    }
  }

  // MARK: - Settings

  /// Tells the watch the phone's settings, and whether to follow them.
  func shareSettings() {
    guard session.activationState == .activated, session.isWatchAppInstalled else { return }
    let settings = Link.Settings(
      share: UserDefaultsManager.shareWatchSettings,
      streamingBitRate: UserDefaultsManager.cellularBitRate,
      downloadBitRate: UserDefaultsManager.downloadBitRate,
      keepPlaying: UserDefaultsManager.keepPlaying)
    do {
      try session.updateApplicationContext(Link.encode(settings))
    } catch {
      debugLog("watch link: settings not sent: \(error)")
    }
  }

  // MARK: - Sending albums

  /// Sends the album at the watch's download bitrate. The songs download
  /// here first, into an outbox of their own, so the phone's downloads and
  /// their bitrate stay as they are.
  func send(_ album: Album) {
    let app = AppModel.shared
    guard let watch else { return app.show("The watch has not answered yet") }
    guard isSignedIn else { return app.show("Sign the watch in first") }
    guard !watch.collections.contains(where: { $0.id == album.id }) else {
      return app.show("Already on the watch")
    }
    guard !sends.contains(where: { $0.id == album.id }) else { return app.show("Already sending") }
    let kbps = Int(watch.downloadBitRate) ?? 0
    sends.append(Send(album: album, songs: max(1, album.songs.count)))
    app.show("Sending \(album.name) to the watch")
    Task {
      let songs = await app.songs(of: album)
      guard !songs.isEmpty else {
        sends.removeAll { $0.id == album.id }
        return app.show("Could not send \(album.name)")
      }
      if let index = sends.firstIndex(where: { $0.id == album.id }) {
        sends[index].songs = songs.count
      }
      WatchSend.shared.enqueue(album, songs: songs, kbps: kbps)
    }
  }

  /// Hands a song or cover in the outbox to the watch.
  func transfer(_ file: URL, _ info: Link.FileInfo) {
    session.transferFile(file, metadata: Link.encode(info))
    updateProgress(info.collectionId)
  }

  /// Recomputes a send's progress: its songs count once downloaded and once
  /// delivered.
  func updateProgress(_ collectionId: String) {
    guard let index = sends.firstIndex(where: { $0.id == collectionId }) else { return }
    let songs = sends[index].songs
    let downloading = WatchSend.shared.pending(collectionId)
    let transferring = outgoing.filter { $0.collectionId == collectionId && $0.kind == .song }.count
    guard downloading + transferring > 0 else {
      sends.remove(at: index)
      return
    }
    sends[index].progress = Double(2 * songs - 2 * downloading - transferring) / Double(2 * songs)
  }

  /// Ends a send that cannot finish, with what is on the way.
  func failSend(_ collectionId: String) {
    WatchSend.shared.cancel(collectionId)
    for transfer in session.outstandingFileTransfers
    where Self.info(of: transfer)?.collectionId == collectionId {
      transfer.cancel()
    }
    if let send = sends.first(where: { $0.id == collectionId }) {
      AppModel.shared.show("Could not send \(send.album.name)")
    }
    sends.removeAll { $0.id == collectionId }
  }

  private var outgoing: [Link.FileInfo] {
    session.outstandingFileTransfers.compactMap(Self.info)
  }

  private static func info(of transfer: WCSessionFileTransfer) -> Link.FileInfo? {
    Link.decode(Link.FileInfo.self, from: transfer.file.metadata ?? [:])
  }

  private func cancelSends() {
    WatchSend.shared.cancelAll()
    session.outstandingFileTransfers.forEach { $0.cancel() }
    sends = []
  }

  // MARK: - From the receiver

  fileprivate func refresh() {
    isPaired = session.isPaired
    isAppInstalled = session.isWatchAppInstalled
    isReachable = session.isReachable
  }

  fileprivate func activated() {
    refresh()
    received(session.receivedApplicationContext)
    shareSettings()
    // Sends of an earlier launch go on: downloads here, transfers with the
    // system.
    let albums = WatchSend.shared.albums + outgoing.filter { $0.kind == .song }.map(\.album)
    for album in albums where !sends.contains(where: { $0.id == album.id }) {
      let songs =
        WatchSend.shared.songCount(album.id)
        ?? outgoing.first { $0.collectionId == album.id }?.songCount ?? 1
      sends.append(Send(album: album, songs: songs))
      updateProgress(album.id)
    }
  }

  fileprivate func received(_ context: [String: Any]) {
    guard let state = Link.decode(Link.WatchState.self, from: context) else { return }
    watch = state
    if signIn == .sending, state.account != nil {
      signIn = .idle
      AppModel.shared.show("Watch signed in")
    }
  }

  fileprivate func signInFailed(_ message: String) {
    signIn = .failed(message)
  }

  fileprivate func transferFinished(_ transfer: WCSessionFileTransfer, error: Error?) {
    let info = Self.info(of: transfer)
    WatchSend.shared.delivered(transfer.file.fileURL)
    guard let info else { return }
    if let error {
      debugLog("watch link: transfer failed: \(error)")
      return failSend(info.collectionId)
    }
    updateProgress(info.collectionId)
  }
}

#if DEBUG
  extension WatchLink {
    /// Stands in for a paired watch in screenshots (FLO_DEBUG_WATCH=demo);
    /// the setters are this file's.
    func showDemo(_ state: Link.WatchState?, sends: [Send]) {
      isPaired = true
      isAppInstalled = true
      isReachable = true
      watch = state
      self.sends = sends
    }
  }
#endif

/// WatchConnectivity calls in on its own queue; this forwards to the main
/// actor.
private final class Receiver: NSObject, WCSessionDelegate {
  func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
  ) {
    debugLog(
      "watch link: activated \(state.rawValue) paired=\(session.isPaired) "
        + "installed=\(session.isWatchAppInstalled) error=\(String(describing: error))")
    Task { @MainActor in WatchLink.shared.activated() }
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  // A switch to another watch: the new one gets a session of its own.
  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in WatchLink.shared.refresh() }
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in WatchLink.shared.refresh() }
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    Task { @MainActor in WatchLink.shared.received(context) }
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard case .signInFailed(let text) = Link.decode(Link.Message.self, from: message) else {
      return
    }
    Task { @MainActor in WatchLink.shared.signInFailed(text) }
  }

  func session(
    _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?
  ) {
    Task { @MainActor in WatchLink.shared.transferFinished(fileTransfer, error: error) }
  }
}
