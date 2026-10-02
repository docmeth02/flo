//
//  PlaybackJournal.swift
//  flo
//

import CoreData
import Foundation

/// How a song came to play. A skip says more about a song the app picked
/// than about one the user did.
enum PlaybackOrigin: String {
  case smartShuffle, keepPlaying, album, playlist, starred, cached, manual
}

/// The journal's recent events of the logged-in account.
struct JournalSnapshot: Sendable {
  /// playbackID → latest heard or skip time, last 48 h.
  var lastHeardAt: [String: Date] = [:]
  /// playbackID → skips in the last 14 d.
  var skips: [String: [SkipEvent]] = [:]

  struct SkipEvent: Sendable {
    let at: Date
    let weight: Double
    let artistKey: String
  }
}

/// The watch's own record of what it played, one HistoryEntity row per heard
/// or skipped song and account. The server's play log knows nothing of skips
/// and hears of offline plays late; the journal covers both for cooldowns
/// and skip penalties. Writes happen on the main thread.
final class PlaybackJournal {
  static let shared = PlaybackJournal()

  /// A skip after at most this much listening is early.
  static let earlySkipSeconds: Double = 10

  private static let retention: TimeInterval = 30 * 86400
  private static let heardWindow: TimeInterval = 48 * 3600
  private static let skipWindow: TimeInterval = 14 * 86400

  private init() {
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: nil) { _ in
      PlaybackJournal.shared.forgetLoggedOutAccounts()
    }
  }

  /// The song qualified as a play.
  func recordHeard(_ item: QueueEntity, origin: PlaybackOrigin, listenedSeconds: Double) {
    record(item, origin: origin, listenedSeconds: listenedSeconds, skipped: false)
  }

  /// The user moved on from the song early. Rows keep the listened time, from
  /// which the snapshot tells early skips apart again.
  func recordSkip(
    _ item: QueueEntity, origin: PlaybackOrigin, listenedSeconds: Double, early: Bool
  ) {
    record(item, origin: origin, listenedSeconds: listenedSeconds, skipped: true, early: early)
  }

  func snapshot() async -> JournalSnapshot {
    guard let key = AuthService.shared.accountKey else { return JournalSnapshot() }
    let now = Date()
    let since = now.addingTimeInterval(-max(Self.heardWindow, Self.skipWindow))

    return await CoreDataManager.shared.performBackground { context in
      var snapshot = JournalSnapshot()
      let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
      request.predicate = NSPredicate(
        format: "accountKey == %@ AND timestamp >= %@", key, since as NSDate)

      for row in (try? context.fetch(request)) ?? [] {
        guard let id = row.songId, !id.isEmpty, let at = row.timestamp else { continue }
        if now.timeIntervalSince(at) <= Self.heardWindow {
          snapshot.lastHeardAt[id] = max(snapshot.lastHeardAt[id] ?? at, at)
        }
        if row.skipped {
          snapshot.skips[id, default: []].append(
            JournalSnapshot.SkipEvent(
              at: at, weight: Self.skipWeight(origin: row.origin, listened: row.listenedSeconds),
              artistKey: row.artistName.map(SmartPlaybackService.artistKey) ?? ""))
        }
      }
      return snapshot
    }
  }

  /// Drops rows older than 30 days, and rows of no account, which nothing
  /// reads: those of builds before the journal.
  func pruneOld() {
    guard !CoreDataManager.shared.isUsingVolatileStore else { return }
    let cutoff = Date().addingTimeInterval(-Self.retention)
    Task {
      let removed = await CoreDataManager.shared.performBackground { context in
        Self.batchDelete(
          NSPredicate(
            format: "timestamp == nil OR timestamp < %@ OR accountKey == nil", cutoff as NSDate),
          in: context)
      }
      debugLog("journal: pruned \(removed) rows")
    }
  }

  // MARK: - Private

  private func record(
    _ item: QueueEntity, origin: PlaybackOrigin, listenedSeconds: Double, skipped: Bool,
    early: Bool = false
  ) {
    guard let key = AuthService.shared.accountKey, let id = item.id, !id.isEmpty else { return }

    let row = HistoryEntity(context: CoreDataManager.shared.viewContext)
    row.accountKey = key
    row.songId = id
    row.trackName = item.songName
    row.artistName = item.artistName
    row.albumId = item.albumId
    row.albumName = item.albumName
    row.origin = origin.rawValue
    row.listenedSeconds = listenedSeconds
    row.skipped = skipped
    row.timestamp = Date()
    CoreDataManager.shared.saveRecord()

    debugLog(
      "journal: \(skipped ? (early ? "early skip" : "skip") : "heard") \(id) "
        + "origin=\(origin.rawValue) listened=\(String(format: "%.1f", listenedSeconds))s")
  }

  /// The local journal belongs to the account that wrote it.
  private func forgetLoggedOutAccounts() {
    guard !CoreDataManager.shared.isUsingVolatileStore else { return }
    let current = AuthService.shared.accountKey
    Task {
      await CoreDataManager.shared.performBackground { context in
        _ = Self.batchDelete(
          current.map { NSPredicate(format: "accountKey != %@", $0) } ?? NSPredicate(value: true),
          in: context)
      }
      debugLog("journal: forgot logged out accounts")
    }
  }

  /// 1.5 for an early skip of a song the app picked, 1 for a later one, 0.75
  /// for a song the user picked.
  private static func skipWeight(origin: String?, listened: Double) -> Double {
    switch origin.flatMap(PlaybackOrigin.init(rawValue:)) {
    case .smartShuffle, .keepPlaying: return listened <= earlySkipSeconds ? 1.5 : 1.0
    default: return 0.75
    }
  }

  private static func batchDelete(_ predicate: NSPredicate, in context: NSManagedObjectContext)
    -> Int
  {
    let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")
    fetch.predicate = predicate
    let request = NSBatchDeleteRequest(fetchRequest: fetch)
    request.resultType = .resultTypeCount
    return ((try? context.execute(request)) as? NSBatchDeleteResult)?.result as? Int ?? 0
  }
}

extension QueueEntity {
  /// Where the queued song came from, told by the queue's name; the queue
  /// keeps no origin of its own.
  var playbackOrigin: PlaybackOrigin {
    switch contextName {
    case "Smart Shuffle": return .smartShuffle
    case "Auto Play": return .keepPlaying
    case "Liked Songs": return .starred
    case "Cached": return .cached
    default: return isFromPlaylist ? .playlist : .album
    }
  }
}
