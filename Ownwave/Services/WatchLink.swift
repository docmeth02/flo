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
  @Published private(set) var sends: [Send] = [] {
    // The watch counts what is still on its way from this; progress alone
    // is the phone's business.
    didSet { if Self.songs(of: sends) != Self.songs(of: oldValue) { updateWatch() } }
  }

  private let session = WCSession.default
  private let receiver = Receiver()
  private var signInDeadline: Task<Void, Never>?

  /// A watch that fails to sign in after the wrist went down cannot say so.
  private static let signInTimeout: Duration = .seconds(60)

  private init() {}

  func activate() {
    guard WCSession.isSupported() else { return }
    session.delegate = receiver
    session.activate()
    AppModel.onLogout { WatchLink.shared.cancelSends() }
    #if DEBUG
      runDebugLaunchActions()
    #endif
  }

  /// The watch is signed in to this phone's account.
  var isSignedIn: Bool {
    watch?.account?.key != nil && watch?.account?.key == AuthService.shared.accountKey
  }

  /// Files can go to the watch: `transferFile` on an inactive session is a
  /// programmer error.
  var canTransfer: Bool {
    session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
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
      case .found(let password) = KeychainManager.loadPassword(),
      let accountKey = AuthService.shared.accountKey
    else {
      signIn = .failed("This iPhone has no saved password to send.")
      return
    }
    signIn = .sending
    signInDeadline?.cancel()
    signInDeadline = Task {
      try? await Task.sleep(for: Self.signInTimeout)
      guard !Task.isCancelled, signIn == .sending else { return }
      signIn = .failed("The watch did not finish signing in.")
    }
    let request = Link.SignIn(
      server: UserDefaultsManager.serverBaseURL, user: auth.username, password: password,
      accountKey: accountKey)
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
    case .alreadySignedIn:
      signInDeadline?.cancel()
      signIn = .idle
    case .otherAccount(let user, let host):
      signIn = .failed("The watch is signed in as \(user) on \(host). Log out there first.")
    case nil: signIn = .failed("The watch did not answer.")
    }
  }

  // MARK: - Settings

  /// Tells the watch the phone's settings, whether to follow them, and the
  /// albums on their way.
  func updateWatch() {
    guard session.activationState == .activated, session.isWatchAppInstalled else { return }
    let phone = Link.PhoneState(
      share: UserDefaultsManager.shareWatchSettings,
      streamingBitRate: UserDefaultsManager.cellularBitRate,
      downloadBitRate: UserDefaultsManager.downloadBitRate,
      keepPlaying: UserDefaultsManager.keepPlaying,
      sending: Self.songs(of: sends))
    do {
      try session.updateApplicationContext(Link.encode(phone))
    } catch {
      RequestLog.shared.note("watch link: settings not sent: \(error.localizedDescription)")
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
    guard !sends.contains(where: { $0.id == album.id }) else { return app.show("Already sending") }
    let kbps = Int(watch.downloadBitRate) ?? 0
    sends.append(Send(album: album, songs: max(1, album.songs.count)))
    let account = AuthService.shared.accountKey
    Task {
      let songs = await app.songs(of: album)
      // A logout meanwhile cleared the sends; these songs are the previous
      // account's.
      guard AuthService.shared.accountKey == account else { return }
      guard !songs.isEmpty else {
        sends.removeAll { $0.id == album.id }
        return app.show("Could not send \(album.name)")
      }
      // A partly arrived album may go again; the songs already there are
      // simply replaced.
      if let there = watch.collections.first(where: { $0.id == album.id }),
        there.songs >= songs.count
      {
        sends.removeAll { $0.id == album.id }
        return app.show("Already on the watch")
      }
      app.show("Sending \(album.name) to the watch")
      if let index = sends.firstIndex(where: { $0.id == album.id }) {
        sends[index].songs = songs.count
      }
      WatchSend.shared.enqueue(album, songs: songs, kbps: kbps)
    }
  }

  /// Hands a song or cover in the outbox to the watch; `WatchSend` only
  /// calls this while `canTransfer`.
  func transfer(_ file: URL, _ info: Link.FileInfo) {
    guard canTransfer else { return }
    session.transferFile(file, metadata: Link.encode(info))
    RequestLog.shared.note(
      "watch link: transfer \(info.kind) \(info.song?.title ?? info.album.name)")
  }

  /// Recomputes a send's progress: its songs count once downloaded and once
  /// transferred, by the bytes sent. A transfer that just finished may still
  /// be listed.
  func updateProgress(_ collectionId: String, excluding finished: WCSessionFileTransfer? = nil) {
    guard let index = sends.firstIndex(where: { $0.id == collectionId }) else { return }
    let songs = sends[index].songs
    let downloading = WatchSend.shared.pending(collectionId)
    let transferring = session.outstandingFileTransfers.filter { transfer in
      guard transfer !== finished, let info = Self.info(of: transfer) else { return false }
      return info.collectionId == collectionId && info.kind == .song
    }
    guard downloading + transferring.count > 0 else {
      sends.remove(at: index)
      return
    }
    let unsent = transferring.reduce(0) { $0 + 1 - $1.progress.fractionCompleted }
    sends[index].progress = (Double(2 * songs - 2 * downloading) - unsent) / Double(2 * songs)
  }

  /// Ends a send that cannot finish, with what is on the way.
  func failSend(_ collectionId: String) {
    if let send = sends.first(where: { $0.id == collectionId }) {
      AppModel.shared.show("Could not send \(send.album.name)")
    }
    stopSend(collectionId)
  }

  /// Ends a send and cancels what is on the way; the album can go again.
  func stopSend(_ collectionId: String) {
    RequestLog.shared.note("watch link: send of \(collectionId) ended")
    WatchSend.shared.cancel(collectionId)
    for transfer in session.outstandingFileTransfers
    where Self.info(of: transfer)?.collectionId == collectionId {
      transfer.cancel()
    }
    sends.removeAll { $0.id == collectionId }
  }

  private static func songs(of sends: [Send]) -> [String: Int] {
    sends.reduce(into: [:]) { $0[$1.id] = $1.songs }
  }

  /// What the system is still transferring, also from an earlier launch.
  var outgoing: [Link.FileInfo] {
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

  /// The watch app was installed, removed or the watch switched: what waited
  /// for the app goes now.
  fileprivate func watchStateChanged() {
    refresh()
    RequestLog.shared.note(
      "watch link: watch paired=\(isPaired) installed=\(isAppInstalled)")
    guard canTransfer else { return }
    updateWatch()
    WatchSend.shared.handOver()
  }

  fileprivate func activated() {
    refresh()
    // Empty after a switch to another watch, which must not inherit the old one's.
    watch = Link.decode(Link.WatchState.self, from: session.receivedApplicationContext)
    updateWatch()
    WatchSend.shared.handOver()
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
    RequestLog.shared.note(
      "watch link: watch reports \(state.collections.count) albums, "
        + "\(state.incoming.values.reduce(0, +)) songs expected")
    watch = state
    if signIn == .sending, state.account != nil {
      signIn = .idle
      signInDeadline?.cancel()
      AppModel.shared.show("Watch signed in")
    }
  }

  fileprivate func signInFailed(_ message: String) {
    signInDeadline?.cancel()
    signIn = .failed(message)
  }

  fileprivate func transferFinished(_ transfer: WCSessionFileTransfer, error: Error?) {
    let info = Self.info(of: transfer)
    WatchSend.shared.delivered(transfer.file.fileURL)
    // A cover is a nicety; the songs decide.
    guard let info, info.kind == .song else { return }
    if let error {
      RequestLog.shared.note("watch link: transfer failed: \(error.localizedDescription)")
      return failSend(info.collectionId)
    }
    RequestLog.shared.note("watch link: delivered \(info.song?.title ?? "")")
    updateProgress(info.collectionId, excluding: transfer)
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
    RequestLog.shared.note(
      "watch link: activated \(state.rawValue) paired=\(session.isPaired) "
        + "installed=\(session.isWatchAppInstalled) "
        + "outstanding=\(session.outstandingFileTransfers.count) \(Self.sent(session))"
        + (error.map { " error=\($0.localizedDescription)" } ?? ""))
    Task { @MainActor in WatchLink.shared.activated() }
  }

  /// How far the system got with what is still outstanding, e.g. "sent=12%".
  static func sent(_ session: WCSession) -> String {
    let transfers = session.outstandingFileTransfers
    guard !transfers.isEmpty else { return "" }
    let done = transfers.reduce(0) { $0 + $1.progress.fractionCompleted } / Double(transfers.count)
    return "sent=\(Int(done * 100))%"
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  // A switch to another watch: the new one gets a session of its own.
  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in WatchLink.shared.watchStateChanged() }
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
