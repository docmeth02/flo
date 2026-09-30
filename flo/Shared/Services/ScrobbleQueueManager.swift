import Combine
import CoreData
import Foundation
import WatchKit

/// Persistent outbox for scrobble submissions that could not be delivered
/// right away. Entries are deleted once the server acknowledges them, retried
/// with a growing delay while the server is unreachable, and dropped only when
/// the server says they can never succeed.
final class ScrobbleQueueManager {
  static let shared = ScrobbleQueueManager()

  private enum Status {
    static let pending = "pending"
    static let failed = "failed"
    // Written by earlier builds for delivered entries; only purged now.
    static let legacySent = "sent"
  }

  private static let initialRetryDelay: TimeInterval = 30
  private static let maxRetryDelay: TimeInterval = 30 * 60

  private var scrobbles: [ScrobbleEntity] = []
  private var isFlushing = false
  private var retryTimer: Timer?
  private var retryDelay = initialRetryDelay
  private var reachability: AnyCancellable?

  private init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleAppBecameActive),
      name: WKApplication.didBecomeActiveNotification, object: nil)

    purgeLegacySent()
    reload()

    // ConnectivityMonitor probes the server on launch, when the network comes
    // back and on demand; every successful probe is a chance to deliver.
    reachability = ConnectivityMonitor.shared.$isServerReachable
      .filter { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.flush() }
  }

  func enqueue(nowPlaying: QueueEntity) {
    guard let songId = nowPlaying.id, !songId.isEmpty else { return }

    let listenTime = Date()

    let isDuplicate = scrobbles.contains { entry in
      entry.songId == songId
        && (entry.listenTime.map { abs($0.timeIntervalSince(listenTime)) < 10 } ?? false)
    }

    guard !isDuplicate else { return }

    let entry = ScrobbleEntity(context: CoreDataManager.shared.viewContext)

    entry.songId = songId
    entry.trackName = nowPlaying.songName
    entry.artistName = nowPlaying.artistName
    entry.albumName = nowPlaying.albumName
    entry.listenTime = listenTime
    entry.queuedAt = Date()
    entry.status = Status.pending

    CoreDataManager.shared.saveRecord()
    reload()
    scheduleRetry()
  }

  /// Drops every queued entry, e.g. on logout: they belong to the previous
  /// account and must not be submitted with the next account's credentials.
  func clearAll() {
    cancelRetry()
    scrobbles.forEach { CoreDataManager.shared.viewContext.delete($0) }
    CoreDataManager.shared.saveRecord()
    reload()
  }

  private func reload() {
    scrobbles = CoreDataManager.shared.getRecordsByEntity(
      entity: ScrobbleEntity.self,
      sortDescriptors: [NSSortDescriptor(key: "queuedAt", ascending: true)])
  }

  private func flush() {
    guard !isFlushing else { return }

    guard !scrobbles.isEmpty else {
      cancelRetry()
      return
    }

    guard ConnectivityMonitor.shared.isOnline, ConnectivityMonitor.shared.isServerReachable else {
      // A successful probe comes back through the reachability subscription.
      ConnectivityMonitor.shared.probeServerReachability()
      scheduleRetry()
      return
    }

    isFlushing = true
    submitPending(scrobbles)
  }

  private func submitPending(_ entries: [ScrobbleEntity]) {
    guard let entry = entries.first else {
      isFlushing = false
      retryDelay = Self.initialRetryDelay
      reload()
      cancelRetry()
      return
    }

    let remaining = Array(entries.dropFirst())

    guard let songId = entry.songId, !songId.isEmpty else {
      delete(entry)
      submitPending(remaining)
      return
    }

    FloooService.shared.scrobbleToBuiltinEndpoint(
      submission: true, songId: songId, time: entry.listenTime ?? Date()
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }

        switch result {
        case .success:
          debugLog("queued scrobble delivered: \(songId)")
          self.delete(entry)
          self.submitPending(remaining)

        case .failure(let error) where FloooService.shared.isPermanentScrobbleFailure(error):
          self.delete(entry)
          self.submitPending(remaining)

        case .failure(let error):
          entry.status = Status.failed
          entry.errorReason = error.localizedDescription
          CoreDataManager.shared.saveRecord()

          self.isFlushing = false
          self.reload()
          self.scheduleRetry()
        }
      }
    }
  }

  private func delete(_ entry: ScrobbleEntity) {
    CoreDataManager.shared.viewContext.delete(entry)
    CoreDataManager.shared.saveRecord()
  }

  /// Retries back off from 30 seconds to 30 minutes so an unreachable server
  /// does not keep the watch radio busy.
  private func scheduleRetry() {
    cancelRetry()

    let delay = retryDelay
    retryDelay = min(retryDelay * 2, Self.maxRetryDelay)

    retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      DispatchQueue.main.async { self?.flush() }
    }
  }

  private func cancelRetry() {
    retryTimer?.invalidate()
    retryTimer = nil
  }

  private func purgeLegacySent() {
    let sent = CoreDataManager.shared.getRecordsByEntity(entity: ScrobbleEntity.self)
      .filter { $0.status == Status.legacySent }

    guard !sent.isEmpty else { return }

    sent.forEach { CoreDataManager.shared.viewContext.delete($0) }
    CoreDataManager.shared.saveRecord()
  }

  @objc private func handleAppBecameActive() {
    flush()
  }
}
