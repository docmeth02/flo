//
//  PlayQueueSync.swift
//  Ownwave
//

import Alamofire
import Combine
import Foundation

/// When the queue is saved to the server: only once it was edited or heard
/// further here since the last save or since it came from elsewhere (a
/// launch restore, an adoption, a handoff); a few seconds after a change, at
/// once on a pause or when the app leaves the foreground. A failed save is
/// dropped: only a later edit or more listening here saves again, so a
/// queue another device saved meanwhile is never overwritten by this one.
struct QueueSaveRules: Equatable {
  private(set) var isDirty = false

  enum Event {
    case changed, advanced, paused, resignedActive
    /// The queue is what another device or the server holds, or the
    /// account went: nothing to save.
    case synced
  }

  enum Action: Equatable { case none, schedule, saveNow, cancel }

  mutating func handle(_ event: Event) -> Action {
    switch event {
    case .advanced:
      isDirty = true
      return .none
    case .changed:
      isDirty = true
      return .schedule
    case .paused, .resignedActive:
      return take()
    case .synced:
      isDirty = false
      return .cancel
    }
  }

  /// The wait after a change is over.
  mutating func debounceEnded() -> Action {
    take()
  }

  private mutating func take() -> Action {
    guard isDirty else { return .none }
    isDirty = false
    return .saveNow
  }
}

/// The queue the server holds, as Navidrome saved it.
struct RemoteQueue: Equatable {
  let songs: [Song]
  let currentIndex: Int
  /// Seconds into the current song.
  let position: Double
  /// The save's time stamp, as the server writes it; only compared.
  let changed: String
  let changedBy: String

  init(songs: [Song], currentIndex: Int, position: Double, changed: String, changedBy: String) {
    self.songs = songs
    self.currentIndex = currentIndex
    self.position = position
    self.changed = changed
    self.changedBy = changedBy
  }

  /// Empty for an answer without a queue.
  init(_ payload: PlayQueueByIndex?) {
    self.init(
      songs: (payload?.entry ?? []).map { $0.toSong() }, currentIndex: payload?.currentIndex ?? 0,
      position: Double(payload?.position ?? 0) / 1000, changed: payload?.changed ?? "",
      changedBy: payload?.changedBy ?? "")
  }
}

/// Saves the queue to the server while "Sync queue" is on, and offers the
/// queue another device saved ("Continue from …"); it never replaces one
/// without being asked.
@MainActor final class PlayQueueSync: ObservableObject {
  static let shared = PlayQueueSync()

  /// A queue another device saved, for the user to take over or turn down.
  struct Offer: Equatable, Identifiable {
    let queue: RemoteQueue
    /// "iPhone", "Apple Watch", or the client that saved it.
    let device: String
    let accountKey: String

    var id: String { queue.changed }
    var song: Song { queue.songs[queue.currentIndex] }

    /// Without listening time, which the server does not keep.
    var snapshot: QueueSnapshot {
      QueueSnapshot(
        entries: queue.songs.map {
          QueueEntry(song: $0, contextName: "Continue from \(device)", isFromPlaylist: false)
        },
        activeIndex: queue.currentIndex, position: queue.position, qualified: false, listened: 0,
        playbackMode: PlaybackMode.defaultPlayback)
    }
  }

  enum NoOffer: String {
    case playing = "playing here"
    case empty = "nothing saved"
    case savedHere = "saved by this device"
    case handled = "taken or turned down"
    case outOfRange = "index out of range"
    case sameAsHere = "same as here"
  }

  enum Decision: Equatable {
    case offer(Offer)
    case none(NoOffer)
  }

  @Published private(set) var offer: Offer?
  @Published var isEnabled = UserDefaultsManager.syncQueue {
    didSet {
      guard isEnabled != oldValue else { return }
      UserDefaultsManager.syncQueue = isEnabled
      RequestLog.shared.trace("queue sync: \(isEnabled ? "on" : "off")")
      if isEnabled { fetch(force: true) } else { reset() }
    }
  }

  /// The client name a save goes by, which the server keeps as its
  /// `changedBy`: "Ownwave iOS", "Ownwave watchOS".
  static let client = client(platform: AppPlatform.name)
  static let debounce: Duration = .seconds(5)
  /// A fetch that is not asked for by the user waits this long after the last.
  static let fetchInterval: TimeInterval = 60
  /// About 1500 songs; the server takes 10 MiB of form.
  static let saveBudget = 400_000

  private weak var player: PlayerViewModel?
  private var events: AnyCancellable?
  private var rules = QueueSaveRules()
  private var debounceTask: Task<Void, Never>?
  // Runs until its last save landed, so saves reach the server in order.
  private var writer: Task<Void, Never>?
  // A save is due; the writer takes the queue as it is when it gets to it.
  private var saveWanted = false
  // Bumped by every fetch and by a reset; only the newest answer counts.
  private var fetchGeneration = 0
  // Bumped by every change or playback here; a fetch from before is stale.
  private var localRevision = 0
  private var lastFetchAt: Date?

  private init() {
    let center = NotificationCenter.default
    center.addObserver(forName: AppPlatform.didBecomeActive, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { PlayQueueSync.shared.fetch(force: false) }
    }
    center.addObserver(forName: AppPlatform.willResignActive, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { PlayQueueSync.shared.apply(.resignedActive) }
    }
    center.addObserver(forName: .didLogin, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { PlayQueueSync.shared.fetch(force: true) }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        PlayQueueSync.shared.reset()
        PlayQueueSync.shared.lastFetchAt = nil
      }
    }
    // Unless the launch's activation asked already.
    ConnectivityMonitor.shared.onFirstVerdict { _ in
      MainActor.assumeIsolated { PlayQueueSync.shared.fetch(force: false) }
    }
  }

  /// Follows `player`, the app's one; again for the same player changes nothing.
  func attach(_ player: PlayerViewModel) {
    guard player !== self.player else { return }
    self.player = player
    events = player.queueEvents.sink { event in
      MainActor.assumeIsolated { PlayQueueSync.shared.handle(event) }
    }
  }

  /// How taking an offer went.
  enum Adoption: Equatable {
    case playing
    /// Its song cannot play here now; the offer stays. What the screens say.
    case unplayable(String)
    /// The offer is no longer the one shown, something plays here
    /// meanwhile, or the queue could not be stored.
    case dropped
  }

  /// Takes over the offered queue and plays it, unless its song can neither
  /// play from this device nor stream now, which would leave a queue that
  /// cannot play in place of this one.
  @discardableResult func adopt(_ offer: Offer) -> Adoption {
    guard offer == self.offer, offer.accountKey == AuthService.shared.accountKey, let player,
      !player.isPlaying
    else { return .dropped }
    if let reason = Self.unplayableReason(
      offer.snapshot, localIds: DownloadStore.localMediaFileIds(),
      streamingAllowed: TranscodingSettings.streamingBitRate != nil,
      serverReachable: ConnectivityMonitor.shared.canReachServer)
    {
      RequestLog.shared.trace("queue sync: the queue from \(offer.device) cannot play: \(reason)")
      return .unplayable(reason)
    }
    self.offer = nil
    guard player.adoptQueue(offer.snapshot, play: true) else {
      RequestLog.shared.trace("queue sync: the queue from \(offer.device) could not be stored")
      return .dropped
    }
    remember(offer)
    RequestLog.shared.trace("queue sync: took the queue from \(offer.device)")
    return .playing
  }

  /// Turns the offer down; that save is not offered again.
  func dismiss(_ offer: Offer) {
    guard offer == self.offer else { return }
    self.offer = nil
    remember(offer)
    RequestLog.shared.trace("queue sync: turned down the queue from \(offer.device)")
  }

  // MARK: - Saving

  private func handle(_ event: PlayerViewModel.QueueEvent) {
    if event == .changed || event == .advanced {
      localRevision += 1
      // The comparison with this queue no longer holds.
      if offer != nil { offer = nil }
    }
    switch event {
    case .changed: apply(.changed)
    case .advanced: apply(.advanced)
    case .synced: apply(.synced)
    case .paused:
      apply(.paused)
      fetch(force: false)
    }
  }

  private func apply(_ event: QueueSaveRules.Event) {
    guard isEnabled else { return }
    switch rules.handle(event) {
    case .none: break
    case .schedule:
      debounceTask?.cancel()
      debounceTask = Task {
        guard (try? await Task.sleep(for: Self.debounce)) != nil else { return }
        if rules.debounceEnded() == .saveNow { requestSave() }
      }
    case .saveNow: requestSave()
    case .cancel: cancelSaves()
    }
  }

  /// Starts the writer unless it runs; it saves once more for a save due
  /// while one is out, after that one landed. The writer starts on a later
  /// turn of the main actor, so an adoption's own pause, which ends with
  /// `.synced`, saves nothing. Once a save landed, the other device's queue
  /// may be asked for.
  private func requestSave() {
    debounceTask?.cancel()
    saveWanted = true
    guard writer == nil else { return }
    writer = Task {
      var landed = false
      while saveWanted {
        saveWanted = false
        guard AuthService.shared.accountKey != nil,
          let snapshot = player?.snapshot(budgetBytes: Self.saveBudget)
        else {
          RequestLog.shared.trace("queue sync: skipped: nothing to save")
          continue
        }
        guard ConnectivityMonitor.shared.canReachServer else {
          RequestLog.shared.trace("queue sync: skipped: offline")
          continue
        }
        landed = await save(snapshot) || landed
      }
      writer = nil
      if landed { fetch(force: false) }
    }
  }

  private func save(_ snapshot: QueueSnapshot) async -> Bool {
    let request: URLRequest
    do {
      request = try Self.saveRequest(
        snapshot, server: UserDefaultsManager.serverBaseURL,
        credentials: AuthService.shared.sessionSnapshot().subsonicCredentials, client: Self.client)
    } catch {
      RequestLog.shared.trace("queue sync: skipped: \(error.localizedDescription)")
      return false
    }
    let response = await APIManager.shared.session.request(request)
      .validate(statusCode: 200..<300)
      .serializingDecodable(SubsonicEnvelope<BasicResponse>.self, automaticallyCancelling: false)
      .response
    ConnectivityMonitor.shared.record(
      response: response.response, error: response.error?.underlyingError)
    let failure: String? =
      switch response.result {
      case .success(let envelope): envelope.failure.map { "\($0.code) \($0.message ?? "")" }
      case .failure(let error): error.localizedDescription
      }
    if let failure {
      RequestLog.shared.trace("queue sync: save failed: \(failure)")
      return false
    }
    RequestLog.shared.trace(
      "queue sync: saved \(snapshot.entries.count) \(snapshot.activeIndex) "
        + "\(Int(snapshot.position)) s")
    return true
  }

  /// A save already sent still lands, before any later one.
  private func cancelSaves() {
    debounceTask?.cancel()
    debounceTask = nil
    saveWanted = false
  }

  /// Sync turned off, or the account went: nothing pending goes, no answer
  /// counts and the offer is gone.
  private func reset() {
    _ = rules.handle(.synced)
    cancelSaves()
    fetchGeneration += 1
    offer = nil
  }

  // MARK: - Offering

  /// Asks the server for its queue while nothing plays here and this
  /// device's own changes are saved; at most every `fetchInterval` unless
  /// `force`.
  private func fetch(force: Bool) {
    guard isEnabled, let player, let account = AuthService.shared.accountKey, !player.isPlaying,
      !rules.isDirty, writer == nil, ConnectivityMonitor.shared.canReachServer
    else { return }
    if !force, let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < Self.fetchInterval {
      return
    }
    lastFetchAt = Date()
    fetchGeneration += 1
    let fetch = fetchGeneration
    let revision = localRevision
    Task {
      let response: DataResponse<SubsonicEnvelope<PlayQueueByIndex>, AFError> =
        await APIManager.shared.subsonicRequest(
          endpoint: API.SubsonicEndpoint.getPlayQueueByIndex, parameters: nil)
      guard fetch == fetchGeneration, AuthService.shared.accountKey == account,
        let player = self.player
      else { return }
      guard revision == localRevision else {
        return RequestLog.shared.trace("queue sync: no offer: changed here meanwhile")
      }
      let payload: PlayQueueByIndex?
      do {
        payload = try response.result.get().payload { $0 }
      } catch {
        // The next occasion asks again.
        lastFetchAt = nil
        return RequestLog.shared.trace("queue sync: fetch failed: \(error.localizedDescription)")
      }
      let decision = Self.decide(
        RemoteQueue(payload), client: Self.client, account: account,
        isPlaying: player.isPlaying, handled: UserDefaultsManager.handledQueueChanges[account],
        localTail: player.nowPlaying == nil ? [] : player.queue[player.activeQueueIdx...].map(\.id),
        localPosition: player.currentPosition)
      switch decision {
      case .offer(let offer):
        if offer != self.offer { RequestLog.shared.trace("queue sync: offer from \(offer.device)") }
        self.offer = offer
      case .none(let reason):
        offer = nil
        RequestLog.shared.trace("queue sync: no offer: \(reason.rawValue)")
      }
    }
  }

  private func remember(_ offer: Offer) {
    UserDefaultsManager.handledQueueChanges[offer.accountKey] = offer.queue.changed
  }
}

// The rules, apart from the app's state, for the tests.
extension PlayQueueSync {
  nonisolated static func client(platform: String) -> String { "\(AppMeta.name) \(platform)" }

  /// "iPhone" or "Apple Watch" for a save by Ownwave, else the client's name.
  nonisolated static func device(_ changedBy: String) -> String {
    switch changedBy {
    case client(platform: "iOS"): "iPhone"
    case client(platform: "watchOS"): "Apple Watch"
    default: changedBy
    }
  }

  /// Whether `remote` is offered here. Not while this device plays, nor a
  /// save of its own, one already taken or turned down, one whose index is
  /// past its songs (the server drops deleted songs without moving it), nor
  /// one that continues as this queue does, within 10 s of its position.
  nonisolated static func decide(
    _ remote: RemoteQueue, client: String, account: String, isPlaying: Bool, handled: String?,
    localTail: [String?], localPosition: Double
  ) -> Decision {
    guard !isPlaying else { return .none(.playing) }
    guard !remote.songs.isEmpty else { return .none(.empty) }
    guard remote.changedBy != client else { return .none(.savedHere) }
    guard remote.changed != handled else { return .none(.handled) }
    guard remote.songs.indices.contains(remote.currentIndex) else { return .none(.outOfRange) }
    let tail = remote.songs[remote.currentIndex...].map { Optional($0.playbackID) }
    if tail == localTail, abs(remote.position - localPosition) <= 10 {
      return .none(.sameAsHere)
    }
    return .offer(Offer(queue: remote, device: device(remote.changedBy), accountKey: account))
  }

  /// Why the current song of `snapshot` cannot start here, as the screens
  /// say it; nil when it can.
  nonisolated static func unplayableReason(
    _ snapshot: QueueSnapshot, localIds: Set<String>, streamingAllowed: Bool,
    serverReachable: Bool
  ) -> String? {
    guard
      !PlayerViewModel.canStart(
        snapshot, localIds: localIds, streamingAllowed: streamingAllowed,
        serverReachable: serverReachable)
    else { return nil }
    return streamingAllowed ? .notAvailableOffline : .streamingBlocked
  }

  /// The form fields of a save; `id` is repeated, one per song.
  struct SaveForm: Encodable {
    let id: [String]
    let currentIndex: Int
    /// Milliseconds.
    let position: Int
  }

  /// The save as a form post, credentials in the query under `client`.
  nonisolated static func saveRequest(
    _ snapshot: QueueSnapshot, server: String, credentials: String, client: String
  ) throws -> URLRequest {
    let url =
      server + API.SubsonicEndpoint.savePlayQueueByIndex
      + Self.credentials(credentials, client: client)
    var request = try URLRequest(url: url, method: .post)
    request.timeoutInterval = 15
    let form = SaveForm(
      id: snapshot.entries.map(\.song.playbackID), currentIndex: snapshot.activeIndex,
      position: Int((snapshot.position * 1000).rounded()))
    // Sorted, the ids would lose the queue's order.
    return try URLEncodedFormParameterEncoder(
      encoder: URLEncodedFormEncoder(alphabetizeKeyValuePairs: false, arrayEncoding: .noBrackets)
    ).encode(form, into: request)
  }

  /// AuthService's encoded credentials with only the client name `c`
  /// replaced; the rest stays as encoded there.
  nonisolated static func credentials(_ query: String, client: String) -> String {
    let name = client.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? client
    return query.split(separator: "&", omittingEmptySubsequences: false)
      .map { item in
        guard let key = item.split(separator: "=").first, key == "c" || key == "?c" else {
          return String(item)
        }
        return "\(key)=\(name)"
      }
      .joined(separator: "&")
  }
}
