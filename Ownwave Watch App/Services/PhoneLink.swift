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
  /// Songs still expected from the phone, per collection.
  @Published private(set) var incoming: [String: Int] = [:]

  private let session = WCSession.default
  private let receiver = Receiver()
  private var lastState: Link.WatchState?
  private var heldTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
  private var observations: [NSKeyValueObservation] = []
  private var downloads: AnyCancellable?

  private init() {}

  func activate() {
    guard WCSession.isSupported() else { return }
    session.delegate = receiver
    session.activate()
    observations = [
      session.observe(\.hasContentPending) { _, _ in
        Task { @MainActor in PhoneLink.shared.completeTasksIfIdle() }
      },
      session.observe(\.activationState) { _, _ in
        Task { @MainActor in PhoneLink.shared.completeTasksIfIdle() }
      },
    ]
    downloads = DownloadSession.shared.downloadFinished
      .receive(on: DispatchQueue.main)
      .sink { _ in PhoneLink.shared.publishState() }
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in PhoneLink.shared.publishState() }
    }
  }

  func isReceiving(collectionId: String) -> Bool {
    (incoming[collectionId] ?? 0) > 0
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

  /// Tells the phone what the watch holds, when that changed.
  func publishState() {
    let followsPhone = UserDefaultsManager.settingsFollowPhone
    let downloadBitRate = UserDefaultsManager.downloadBitRate
    let incoming = incoming
    var account: Link.WatchState.Account?
    if let key = AuthService.shared.accountKey, case .found(let auth) = KeychainManager.loadAuth() {
      account = .init(
        user: auth.username, host: URL(string: UserDefaultsManager.serverBaseURL)?.host ?? "",
        key: key)
    }
    receiver.account = account
    Task {
      var state = await Self.inventory()
      state.account = account
      state.followsPhone = followsPhone
      state.downloadBitRate = downloadBitRate
      state.incoming = incoming
      self.send(state)
    }
  }

  // MARK: - From the receiver

  fileprivate func activated() {
    apply(session.receivedApplicationContext)
    publishState()
    completeTasksIfIdle()
  }

  fileprivate func apply(_ context: [String: Any]) {
    guard let settings = Link.decode(Link.Settings.self, from: context) else { return }
    // Turned off, the watch keeps the values it followed last.
    if settings.share {
      UserDefaultsManager.maxBitRate = settings.streamingBitRate
      UserDefaultsManager.downloadBitRate = settings.downloadBitRate
      UserDefaultsManager.keepPlaying = settings.keepPlaying
    }
    UserDefaultsManager.settingsFollowPhone = settings.share
    objectWillChange.send()
    publishState()
  }

  fileprivate func requestSignIn(_ request: Link.SignIn) {
    signInRequest = request
  }

  /// Records a song or cover whose file is already in place.
  fileprivate func save(_ info: Link.FileInfo) {
    defer {
      receiver.finishedDelivery()
      completeTasksIfIdle()
    }
    let service = AlbumService.shared
    if info.kind == .song, let song = info.song {
      service.saveAlbum(info.album)
      guard
        service.saveDownload(
          albumId: info.collectionId, albumName: info.album.name, song: song, suffix: info.suffix,
          bitRate: info.kbps > 0 ? info.kbps : song.bitRate, status: "Downloaded")
      else { return RequestLog.shared.note("phone song \(song.title) not saved") }
    }
    let have = service.downloadedMediaFileIds(collectionId: info.collectionId).count
    incoming[info.collectionId] = max(0, info.songCount - have)
    if incoming[info.collectionId] == 0 { incoming[info.collectionId] = nil }
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
      debugLog("phone link: state not sent: \(error)")
    }
  }

  private func completeTasksIfIdle() {
    guard !heldTasks.isEmpty, session.activationState == .activated, !session.hasContentPending,
      !receiver.isDelivering
    else { return }
    heldTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
    heldTasks = []
  }

  /// The downloaded collections with their song counts and bitrates, the
  /// size of the downloads and the room left.
  private static func inventory() async -> Link.WatchState {
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
          id: id, name: collection.name ?? "", artist: collection.albumArtist ?? "",
          songs: songs.count, kbps: rates.count == 1 ? rates.first.map(Int.init) : nil)
      }
      return state
    }
    state.musicBytes = await bytes
    let free = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    state.freeBytes = Int64(free?.volumeAvailableCapacity ?? 0)
    return state
  }
}

/// WatchConnectivity calls in on its own queue; this forwards to the main
/// actor and does the one thing that cannot wait: a received file is gone
/// once its callback returns.
private final class Receiver: NSObject, WCSessionDelegate {
  private let lock = NSLock()
  private var _account: Link.WatchState.Account?
  private var deliveries = 0

  /// The signed-in account, kept here for the delegate queue.
  var account: Link.WatchState.Account? {
    get { lock.withLock { _account } }
    set { lock.withLock { _account = newValue } }
  }

  var isDelivering: Bool { lock.withLock { deliveries > 0 } }

  func finishedDelivery() {
    lock.withLock { deliveries -= 1 }
  }

  func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
  ) {
    if let error { debugLog("phone link: activation failed: \(error)") }
    Task { @MainActor in PhoneLink.shared.activated() }
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
    guard let account else {
      replyHandler(Link.encode(Link.Reply.accepted))
      Task { @MainActor in PhoneLink.shared.requestSignIn(request) }
      return
    }
    let same = account.user == request.user && account.host == URL(string: request.server)?.host
    replyHandler(
      Link.encode(same ? .alreadySignedIn : Link.Reply.otherAccount(user: account.user, host: account.host)))
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    guard let metadata = file.metadata, let info = Link.decode(Link.FileInfo.self, from: metadata),
      info.accountKey == account?.key
    else { return debugLog("phone link: dropped a file for another account") }
    let path =
      switch info.kind {
      case .song:
        info.song.map {
          AlbumService.downloadPath(
            collectionId: info.collectionId, mediaFileId: $0.id, suffix: info.suffix)
        }
      case .cover: AlbumService.coverPath(id: info.collectionId)
      }
    guard let path else { return }
    let target = LocalFileManager.shared.fileURL(for: path)
    do {
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: file.fileURL, to: target)
    } catch {
      return debugLog("phone link: file not moved: \(error)")
    }
    lock.withLock { deliveries += 1 }
    Task { @MainActor in PhoneLink.shared.save(info) }
  }
}
