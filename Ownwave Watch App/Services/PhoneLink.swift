//
//  PhoneLink.swift
//  Ownwave Watch App
//

import Combine
import WatchConnectivity
import WatchKit

/// The watch's side of the link with the iPhone app: it follows the phone's
/// settings while sharing is on, signs in when the phone asks, takes albums
/// the phone sends, and tells the phone what it holds.
@MainActor final class PhoneLink: ObservableObject {
  static let shared = PhoneLink()

  /// A sign-in the phone asked for; `WatchContentView` runs it with the
  /// watch's own login.
  @Published private(set) var signInRequest: Link.SignIn?
  /// Songs still expected from the phone per collection: what the phone
  /// says it is sending, less what is here.
  @Published private(set) var incoming: [String: Int] = [:]
  private var sending: [String: Int] = [:]

  private let session = WCSession.default
  let receiver = PhoneLinkReceiver()
  private var lastState: Link.WatchState?
  private var heldTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
  private var observations: [NSKeyValueObservation] = []
  private var downloads: AnyCancellable?

  private init() {}

  func activate() {
    guard WCSession.isSupported() else { return }
    session.delegate = receiver
    session.activate()
    #if DEBUG
      runDebugLaunchActions()
    #endif
    observations = [
      session.observe(\.hasContentPending) { _, _ in
        Task { @MainActor in PhoneLink.shared.completeTasksIfIdle() }
      },
      session.observe(\.activationState) { _, _ in
        Task { @MainActor in PhoneLink.shared.completeTasksIfIdle() }
      },
    ]
    // An album downloading here finishes song by song; one state for a run.
    // A deletion changes the inventory too, or the phone keeps refusing to
    // send what is gone.
    downloads = DownloadSession.shared.downloadFinished.map { _ in () }
      .merge(
        with: DownloadSession.shared.downloadsRemoved, DownloadSession.shared.$jobs.map { _ in () }
      )
      .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
      .sink { _ in PhoneLink.shared.publishState() }
    // Files of the old account are dropped from now on. The login change
    // itself is published by WatchContentView.
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in PhoneLink.shared.forgetSends() }
    }
  }

  func isReceiving(collectionId: String) -> Bool {
    incoming[collectionId] != nil
  }

  /// Finished songs of a collection the phone is sending, in percent.
  func progress(collectionId: String, songs: Int) -> Int {
    let left = incoming[collectionId] ?? 0
    return songs + left == 0 ? 0 : songs * 100 / (songs + left)
  }

  /// Keeps a wake-up for the link until its content is delivered and saved.
  func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
    heldTasks.append(task)
    completeTasksIfIdle()
  }

  /// The watch's sign-in ended: on success the next state says so, a failure
  /// goes back to the phone.
  func signInFinished(error: String?) {
    guard signInRequest != nil else { return }
    signInRequest = nil
    if let error, session.isReachable {
      session.sendMessage(Link.encode(Link.Message.signInFailed(error)), replyHandler: nil)
    }
    publishState()
  }

  /// Tells the phone what the watch holds, when that changed. A watch
  /// without the iPhone app does none of the work.
  func publishState() {
    guard session.activationState == .activated, session.isCompanionAppInstalled else { return }
    let downloadBitRate = UserDefaultsManager.downloadBitRate
    let incoming = incoming
    let account = PhoneLinkReceiver.signedInAccount()
    let downloading = DownloadSession.shared.jobs.filter { !$0.failed }
      .reduce(into: [String: Int]()) { $0[$1.collectionId, default: 0] += 1 }
    Task {
      var state = await Self.inventory(downloading: downloading)
      state.account = account
      state.downloadBitRate = downloadBitRate
      state.incoming = incoming
      self.send(state)
    }
  }

  // MARK: - From the receiver

  fileprivate func activated() {
    companionChanged()
    // The last context outlives the iPhone app; only a present one is followed.
    if !session.isCompanionAppInstalled || !apply(session.receivedApplicationContext) {
      publishState()
    }
    completeTasksIfIdle()
  }

  /// Without the iPhone app nothing can turn sharing off again, so the
  /// watch's settings are its own once more.
  fileprivate func companionChanged() {
    guard !session.isCompanionAppInstalled else { return }
    UserDefaultsManager.settingsFollowPhone = false
    forgetSends()
  }

  /// Applies the phone's settings and sends and publishes; false for a
  /// context without them.
  @discardableResult func apply(_ context: [String: Any]) -> Bool {
    guard let phone = Link.decode(Link.PhoneState.self, from: context) else { return false }
    RequestLog.shared.note(
      "phone link: phone share=\(phone.share) sending=\(phone.sending.values.reduce(0, +)) songs")
    // Turned off, the watch keeps the values it followed last.
    if phone.share {
      UserDefaultsManager.maxBitRate = phone.streamingBitRate
      UserDefaultsManager.downloadBitRate = phone.downloadBitRate
      UserDefaultsManager.keepPlaying = phone.keepPlaying
      if let cellular = phone.downloadOverCellular,
        cellular != UserDefaultsManager.downloadOverCellular
      {
        UserDefaultsManager.downloadOverCellular = cellular
        DownloadSession.shared.cellularAccessChanged()
      }
      if let variety = phone.mixVariety.flatMap(MixRanker.Variety.init) {
        UserDefaultsManager.mixVariety = variety
      }
    }
    UserDefaultsManager.settingsFollowPhone = phone.share
    sending = phone.sending
    recountIncoming()
    publishState()
    return true
  }

  private func forgetSends() {
    sending = [:]
    incoming = [:]
  }

  private func recountIncoming() {
    incoming = sending.reduce(into: [:]) { left, album in
      let here = DownloadStore.downloadedMediaFileIds(collectionId: album.key).count
      if album.value > here { left[album.key] = album.value - here }
    }
  }

  func requestSignIn(_ request: Link.SignIn) {
    signInRequest = request
  }

  /// Records a song or cover whose file is already in place.
  fileprivate func save(_ info: Link.FileInfo) {
    defer {
      receiver.finishedDelivery()
      completeTasksIfIdle()
    }
    if info.kind == .song, let song = info.song {
      DownloadStore.saveAlbum(info.album)
      guard
        DownloadStore.saveDownload(
          albumId: info.collectionId, albumName: info.album.name, song: song, suffix: info.suffix,
          bitRate: info.kbps > 0 ? info.kbps : song.bitRate)
      else { return RequestLog.shared.note("phone song \(song.title) not saved") }
    }
    recountIncoming()
    DownloadSession.shared.downloadFinished.send(info.collectionId)
  }

  // MARK: - Private

  private func send(_ state: Link.WatchState) {
    guard session.activationState == .activated, session.isCompanionAppInstalled,
      state != lastState
    else { return }
    do {
      try session.updateApplicationContext(Link.encode(state))
      lastState = state
    } catch {
      RequestLog.shared.note("phone link: state not sent: \(error.localizedDescription)")
    }
  }

  private func completeTasksIfIdle() {
    guard !heldTasks.isEmpty, session.activationState == .activated, !session.hasContentPending,
      !receiver.isDelivering
    else { return }
    heldTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
    heldTasks = []
  }

  /// The downloaded collections with their song counts, bitrates and songs
  /// still downloading, the size of the downloads and the room left.
  private static func inventory(downloading: [String: Int]) async -> Link.WatchState {
    async let bytes = LocalFileManager.shared.downloadsBytes()
    var state = await CoreDataManager.shared.performBackground { context in
      let collections = (try? context.fetch(PlaylistEntity.fetchRequest())) ?? []
      let songs = (try? context.fetch(SongEntity.fetchRequest())) ?? []
      let byCollection = Dictionary(grouping: songs, by: \.albumId)
      var state = Link.WatchState()
      state.collections = collections.compactMap { collection in
        guard let id = collection.id, let songs = byCollection[id], !songs.isEmpty else {
          return nil
        }
        let rates = Set(songs.map(\.bitRate))
        return .init(
          id: id, name: collection.name ?? "", songs: songs.count,
          kbps: rates.count == 1 ? rates.first.map(Int.init) : nil, downloading: downloading[id])
      }
      return state
    }
    state.musicBytes = await bytes
    state.freeBytes = StorageUsage.freeBytes()
    return state
  }
}

/// WatchConnectivity calls in on its own queue; this forwards to the main
/// actor and does the one thing that cannot wait: a received file is gone
/// once its callback returns.
final class PhoneLinkReceiver: NSObject, WCSessionDelegate {
  private let lock = NSLock()
  private var deliveries = 0

  /// The signed-in account, from the session's own key, which is safe to
  /// read on any queue and set before the first file can arrive. The name
  /// comes from the Keychain when it reads.
  static func signedInAccount() -> Link.WatchState.Account? {
    guard let key = AuthService.shared.accountKey else { return nil }
    var user = ""
    if case .found(let auth) = KeychainManager.loadAuth() { user = auth.username }
    return .init(
      user: user, host: URL(string: UserDefaultsManager.serverBaseURL)?.host ?? "", key: key)
  }

  var isDelivering: Bool { lock.withLock { deliveries > 0 } }

  func finishedDelivery() {
    lock.withLock { deliveries -= 1 }
  }

  func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
  ) {
    RequestLog.shared.note(
      "phone link: activated \(state.rawValue) companion=\(session.isCompanionAppInstalled)"
        + (error.map { " error=\($0.localizedDescription)" } ?? ""))
    Task { @MainActor in PhoneLink.shared.activated() }
  }

  func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
    Task { @MainActor in PhoneLink.shared.companionChanged() }
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    Task { @MainActor in PhoneLink.shared.apply(context) }
  }

  func session(
    _ session: WCSession, didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard case .signIn(let request) = Link.decode(Link.Message.self, from: message) else {
      return replyHandler([:])
    }
    // A signed-in watch keeps its login; signing in again is its own choice.
    guard let account = Self.signedInAccount() else {
      replyHandler(Link.encode(Link.Reply.accepted))
      Task { @MainActor in PhoneLink.shared.requestSignIn(request) }
      return
    }
    let same = account.key == request.accountKey
    replyHandler(
      Link.encode(
        same ? .alreadySignedIn : Link.Reply.otherAccount(user: account.user, host: account.host)))
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    receive(file.fileURL, metadata: file.metadata ?? [:])
  }

  /// Moves a file from the phone into place, before its callback returns.
  func receive(_ file: URL, metadata: [String: Any]) {
    guard let info = Link.decode(Link.FileInfo.self, from: metadata) else {
      return RequestLog.shared.note("phone link: dropped a file without its details")
    }
    guard info.accountKey == AuthService.shared.accountKey else {
      return RequestLog.shared.note("phone link: dropped \(info.kind) for another account")
    }
    let path =
      switch info.kind {
      case .song:
        info.song.map {
          DownloadStore.downloadPath(
            collectionId: info.collectionId, mediaFileId: $0.id, suffix: info.suffix)
        }
      case .cover: DownloadStore.coverPath(id: info.collectionId)
      }
    guard let path else { return }
    do {
      try LocalFileManager.shared.moveFile(
        source: file, target: LocalFileManager.shared.fileURL(for: path))
    } catch {
      return RequestLog.shared.note("phone link: file not moved: \(error.localizedDescription)")
    }
    RequestLog.shared.note(
      "phone link: received \(info.kind) \(info.song?.title ?? info.album.name)")
    lock.withLock { deliveries += 1 }
    Task { @MainActor in PhoneLink.shared.save(info) }
  }
}
