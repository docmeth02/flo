import Combine
import CoreData
import Foundation
import WatchKit

/// What a scrobble needs, copied from the queue entry when the listen
/// happens: the entry itself can be deleted by the time a failed submission
/// has to be queued.
struct ScrobblePayload {
  let songId: String
  let listenTime: Date
  // Logout bumps the outbox generation; a submission that fails afterwards
  // belongs to the previous account and must not be queued.
  let accountGeneration: Int

  init?(
    nowPlaying: QueueEntity,
    accountGeneration: Int = ScrobbleQueueManager.shared.accountGeneration
  ) {
    guard let songId = nowPlaying.id, !songId.isEmpty else { return nil }
    self.songId = songId
    self.listenTime = Date()
    self.accountGeneration = accountGeneration
  }
}

/// Persistent outbox for scrobble submissions that could not be delivered
/// right away. Entries are deleted once the server acknowledges them, retried
/// with a growing delay while the server is unreachable or no login can be
/// read, and dropped only when the server says they can never succeed.
final class ScrobbleQueueManager {
  static let shared = ScrobbleQueueManager()

  /// Submits one listen to the server; the completion may run on any thread.
  typealias Send = (
    _ songId: String, _ time: Date, _ completion: @escaping (Result<Void, Error>) -> Void
  ) -> Void

  private enum Status {
    static let pending = "pending"
    static let failed = "failed"
  }

  private static let initialRetryDelay: TimeInterval = 30
  private static let maxRetryDelay: TimeInterval = 30 * 60

  private var scrobbles: [ScrobbleEntity] = []
  private var isFlushing = false
  private var flushRequested = false
  private var retryTimer: Timer?
  private(set) var retryDelay = initialRetryDelay
  private var triggers: AnyCancellable?
  private(set) var accountGeneration = 0
  // What pendingListens returns, renewed with every reload.
  private var listens: [(songId: String, at: Date)] = []
  private let listensLock = NSLock()

  private let store: CoreDataManager
  private let receipts: ScrobbleReceipts
  private let accountKey: () -> String?
  private let send: Send
  private let canReachServer: () -> Bool
  private let probeServer: () -> Void

  /// The parameters are for tests; the app uses the shared store, the
  /// receipts file, AuthService, the server and ConnectivityMonitor. Each
  /// value `flushTriggers` publishes on the main thread is a chance to
  /// deliver.
  init(
    store: CoreDataManager = .shared,
    receipts: ScrobbleReceipts = ScrobbleReceipts(),
    accountKey: @escaping () -> String? = { AuthService.shared.accountKey },
    send: @escaping Send = { songId, time, completion in
      FloooService.shared.scrobbleToBuiltinEndpoint(
        submission: true, songId: songId, time: time, completion: completion)
    },
    canReachServer: @escaping () -> Bool = { ConnectivityMonitor.shared.canReachServer },
    probeServer: @escaping () -> Void = { ConnectivityMonitor.shared.probeServerReachability() },
    flushTriggers: AnyPublisher<Void, Never> = ScrobbleQueueManager.appAndServerTriggers()
  ) {
    self.store = store
    self.receipts = receipts
    self.accountKey = accountKey
    self.send = send
    self.canReachServer = canReachServer
    self.probeServer = probeServer

    reload()
    // A memory store shows none of the rows the receipts were written for.
    if !store.isUsingVolatileStore {
      receipts.keep(rows: Set(scrobbles.map(Self.rowID)))
    }

    triggers = flushTriggers.sink { [weak self] in self?.flush() }
  }

  /// Every return to the app, and every successful probe: ConnectivityMonitor
  /// probes the server on launch, when the network comes back and on demand.
  static func appAndServerTriggers() -> AnyPublisher<Void, Never> {
    NotificationCenter.default.publisher(for: WKApplication.didBecomeActiveNotification)
      .map { _ in }
      .merge(
        with: ConnectivityMonitor.shared.$isServerReachable
          .filter { $0 }
          .map { _ in }
          .receive(on: DispatchQueue.main)
      )
      .eraseToAnyPublisher()
  }

  /// Submissions waiting for the server. Main thread only.
  var pendingCount: Int { scrobbles.count }

  /// Counted plays still waiting in the outbox for the current account, as
  /// (song playback id, listen time). Thread-safe snapshot.
  func pendingListens() -> [(songId: String, at: Date)] {
    guard accountKey() != nil else { return [] }
    return listensLock.withLock { listens }
  }

  func enqueue(_ payload: ScrobblePayload) {
    guard payload.accountGeneration == accountGeneration else { return }

    let isDuplicate = scrobbles.contains { entry in
      entry.songId == payload.songId
        && (entry.listenTime.map { abs($0.timeIntervalSince(payload.listenTime)) < 10 } ?? false)
    }

    guard !isDuplicate else { return }

    let entry = ScrobbleEntity(context: store.viewContext)

    entry.songId = payload.songId
    entry.listenTime = payload.listenTime
    entry.queuedAt = Date()
    entry.status = Status.pending

    guard store.saveRecord() else {
      // The store failed and dropped the entry; one direct attempt beats
      // losing the play.
      send(payload.songId, payload.listenTime) { _ in }
      return
    }
    reload()

    if canReachServer() {
      flush()
    } else {
      scheduleRetry()
    }
  }

  /// Drops every queued entry, e.g. on logout: they belong to the previous
  /// account and must not be submitted with the next account's credentials.
  func clearAll() {
    accountGeneration += 1
    cancelRetry()
    scrobbles.forEach { store.viewContext.delete($0) }
    // Rows a failed delete brings back keep their receipts.
    if store.saveRecord() { receipts.removeAll() }
    reload()
  }

  private func reload() {
    scrobbles = store.getRecordsByEntity(
      entity: ScrobbleEntity.self,
      sortDescriptors: [NSSortDescriptor(key: "queuedAt", ascending: true)])
    let listens = scrobbles.compactMap { entry in
      entry.songId.flatMap { songId in entry.listenTime.map { (songId: songId, at: $0) } }
    }
    listensLock.withLock { self.listens = listens }
  }

  private static func rowID(_ entry: ScrobbleEntity) -> String {
    entry.objectID.uriRepresentation().absoluteString
  }

  private func flush() {
    guard !isFlushing else {
      // A retry or a listen landing mid-flush must not be lost.
      flushRequested = true
      scheduleRetry()
      return
    }

    guard !scrobbles.isEmpty else {
      cancelRetry()
      return
    }

    guard canReachServer() else {
      // A successful probe comes back through the flush triggers.
      probeServer()
      backOff()
      scheduleRetry()
      return
    }

    // Without credentials the server would refuse every listen for good.
    guard accountKey() != nil else {
      backOff()
      scheduleRetry()
      return
    }

    isFlushing = true
    flushRequested = false
    // A timer firing mid-flush would request a second pass over the same rows.
    cancelRetry()
    submitPending(scrobbles)
  }

  private func submitPending(_ entries: [ScrobbleEntity]) {
    guard let entry = entries.first else {
      isFlushing = false
      reload()
      NotificationCenter.default.post(name: .scrobbleOutboxFlushed, object: nil)
      if scrobbles.isEmpty { retryDelay = Self.initialRetryDelay }
      // Entries queued during this flush go out now. Rows left over (queued
      // while the server looked unreachable, or a delete that failed to save)
      // come back with a growing delay.
      if flushRequested {
        flushRequested = false
        flush()
      } else if scrobbles.isEmpty {
        cancelRetry()
      } else {
        backOff()
        scheduleRetry()
      }
      return
    }

    let remaining = Array(entries.dropFirst())
    // A row one server took is never sent again, to any account.
    let receipt = ScrobbleReceipts.Receipt(row: Self.rowID(entry))

    guard let songId = entry.songId, !songId.isEmpty, !receipts.contains(receipt) else {
      if delete(entry) { receipts.remove(receipt) }
      submitPending(remaining)
      return
    }

    let generation = accountGeneration
    send(songId, entry.listenTime ?? Date()) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        // A logout meanwhile deleted the entry; it must not be touched again.
        guard generation == self.accountGeneration else {
          self.isFlushing = false
          return
        }

        switch result {
        case .success:
          debugLog("queued scrobble delivered: \(songId)")
          self.receipts.insert(receipt)
          if self.delete(entry) { self.receipts.remove(receipt) }
          self.submitPending(remaining)

        case .failure(let error) where FloooService.shared.isPermanentFailure(error):
          self.delete(entry)
          self.submitPending(remaining)

        case .failure:
          entry.status = Status.failed
          self.store.saveRecord()

          self.isFlushing = false
          self.reload()
          self.backOff()
          self.scheduleRetry()
        }
      }
    }
  }

  /// Whether the delete saved.
  @discardableResult
  private func delete(_ entry: ScrobbleEntity) -> Bool {
    store.viewContext.delete(entry)
    return store.saveRecord()
  }

  /// Schedules the next delivery attempt unless one is already pending, so
  /// new listens never push an existing retry further out.
  private func scheduleRetry() {
    guard retryTimer == nil else { return }

    retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) {
      [weak self] _ in
      DispatchQueue.main.async {
        self?.retryTimer = nil
        self?.flush()
      }
    }
  }

  /// After a failed attempt the next one waits twice as long, from 30 seconds
  /// up to 30 minutes, so an unreachable server does not keep the radio busy.
  private func backOff() {
    cancelRetry()
    retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
  }

  private func cancelRetry() {
    retryTimer?.invalidate()
    retryTimer = nil
  }
}
