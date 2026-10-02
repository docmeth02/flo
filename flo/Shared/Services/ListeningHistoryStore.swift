//
//  ListeningHistoryStore.swift
//  flo
//

import Alamofire
import CoreData
import Foundation
import WatchKit

/// Where the history import of the logged-in account stands, for the
/// diagnostics screen and the share log.
struct ImportState: Sendable, Equatable {
  enum Phase: Sendable, Equatable {
    case idle
    case importing(page: Int)
    case complete
    case failed(String)
    case skipped(String)
  }

  var phase: Phase = .idle
  var serverTotal = 0
  var importedCount = 0
  var matchedCount = 0
  var earliestPlayAt: Date?
  var lastImportAt: Date?
  var watermarkId: Int64 = 0
  var bootstrapComplete = false
  /// Pages fetched by the latest run.
  var pages = 0

  /// Mirrored plays whose song was not in the library when they came in.
  var unmatchedCount: Int { importedCount - matchedCount }
}

/// Decayed listening aggregates of the logged-in account, evaluated at `now`.
struct AffinitySnapshot: Sendable {
  enum Kind: Int16, Sendable, CaseIterable {
    case artist = 0
    case album = 1
    case genre = 2
    case era = 3
    case song = 4
  }

  struct Aggregate: Sendable {
    let weight: Double
    let lastPlayAt: Date?
    let plays: Int
  }

  var aggregates: [Kind: [String: Aggregate]] = [:]
  var state = ImportState()
  /// Plays the server stamped in the future; they count as played now.
  var futurePlays = 0
}

/// The import state for SwiftUI.
@MainActor final class HistoryStatus: ObservableObject {
  static let shared = HistoryStatus()

  @Published var state = ImportState()
}

/// Mirrors the server's play log (Navidrome's /api/scrobble, one row per
/// counted play from any client) per account and folds it into time-decayed
/// aggregates. Rows are walked by server id, newest first: a late offline
/// scrobble from another client carries an old time but a new id.
actor ListeningHistoryStore {
  static let shared = ListeningHistoryStore()

  enum Reason: String, Sendable {
    case activation, mix, outbox, scrobble, rebuild, debug
  }

  /// Half-life of positive affinity. Changing how plays are folded needs a
  /// new aggregate version, which rebuilds every account's aggregates.
  static let halfLife: TimeInterval = 60 * 86400
  static let aggregateVersion: Int16 = 1

  private static let pageSize = 1000
  private static let firstPageSize = 100
  // Rows re-read when a bootstrap continues, in case the offsets moved.
  private static let pageOverlap = 50
  private static let staleAfter: TimeInterval = 5 * 60
  private static let scrobbleDelay: UInt64 = 120

  private var run: (id: UUID, task: Task<Void, Never>)?
  private var scrobbleRefreshPending = false
  // A failed run holds the triggers off as long as a successful one would.
  private var lastFailedAt: Date?

  private init() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: WKApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { _ in
      Task { await ListeningHistoryStore.shared.refreshIfStale(reason: .activation) }
    }
    center.addObserver(forName: .scrobbleOutboxFlushed, object: nil, queue: nil) { _ in
      Task { await ListeningHistoryStore.shared.refreshIfStale(reason: .outbox) }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: nil) { _ in
      Task { await ListeningHistoryStore.shared.forgetLoggedOutAccounts() }
    }
  }

  // MARK: - Triggers

  /// Imports unless the last successful import, or the last failed attempt,
  /// is under five minutes old.
  func refreshIfStale(reason: Reason) async {
    guard let key = AuthService.shared.accountKey, run == nil else { return }
    if let failed = lastFailedAt, Date().timeIntervalSince(failed) < Self.staleAfter { return }
    let last = await CoreDataManager.shared.performBackground { context in
      Self.stateEntity(for: key, in: context)?.lastImportAt
    }
    if let last, Date().timeIntervalSince(last) < Self.staleAfter { return }
    await refresh(reason: reason)
  }

  /// Imports what the server logged since the last run; joins a run in flight.
  func refresh(reason: Reason) async {
    if let run { return await run.task.value }
    await start(reason: reason, reset: false)
  }

  /// A scrobble from this watch reached the server: import it once things
  /// settle, at most every two minutes.
  nonisolated func scrobbleDelivered() {
    Task { await self.scheduleScrobbleRefresh() }
  }

  /// Throws the account's mirror and aggregates away and imports everything
  /// again. The old aggregates stay readable until the first page lands.
  func rebuild() async {
    while let run {
      run.task.cancel()
      await run.task.value
    }
    await start(reason: .rebuild, reset: true)
  }

  private func scheduleScrobbleRefresh() async {
    guard !scrobbleRefreshPending else { return }
    scrobbleRefreshPending = true
    try? await Task.sleep(nanoseconds: Self.scrobbleDelay * 1_000_000_000)
    scrobbleRefreshPending = false
    await refreshIfStale(reason: .scrobble)
  }

  private func start(reason: Reason, reset: Bool) async {
    let id = UUID()
    let task = Task { await self.performImport(reason: reason, reset: reset, runId: id) }
    run = (id, task)
    await task.value
  }

  private func finishRun(_ id: UUID) {
    if run?.id == id { run = nil }
  }

  /// After a logout nobody's history may stay behind: the rows of every
  /// account but the one logged in now (none) go.
  private func forgetLoggedOutAccounts() async {
    while let run {
      run.task.cancel()
      await run.task.value
    }
    await publish(ImportState())
    guard !CoreDataManager.shared.isUsingVolatileStore else { return }

    let current = AuthService.shared.accountKey
    await MainActor.run {
      let predicate = current.map { NSPredicate(format: "accountKey != %@", $0) }
      for entity in ["PlayEntity", "AffinityEntity", "HistorySyncStateEntity"] {
        CoreDataManager.shared.batchDelete(entityName: entity, predicate: predicate)
      }
    }
    debugLog("history: forgot logged out accounts")
  }

  // MARK: - Import

  /// Loop control copied out of HistorySyncStateEntity.
  private struct Progress: Sendable {
    var generation: Int16
    var watermarkId: Int64
    var bootstrapComplete: Bool
    var bootstrapNextStart: Int
  }

  private struct PageResult: Sendable {
    let state: ImportState
    let progress: Progress
    let inserted: Int
    let matched: Int
  }

  private func performImport(reason: Reason, reset: Bool, runId: UUID) async {
    defer { finishRun(runId) }
    guard let key = AuthService.shared.accountKey else { return }

    guard !CoreDataManager.shared.isUsingVolatileStore else {
      await publishState(key, phase: .skipped("storage unavailable"))
      return
    }
    guard await ConnectivityMonitor.shared.canStream() else {
      await publishState(key, phase: .failed("server unreachable"))
      return
    }

    var progress = await CoreDataManager.shared.performBackground { context in
      Self.loadProgress(for: key, reset: reset, in: context)
    }
    let index = await SmartPlaybackService.shared.libraryIndex()
    guard isCurrent(key) else { return }
    guard !index.songs.isEmpty else {
      await publishState(key, phase: .failed("library unavailable"))
      return
    }

    debugLog(
      "history import (\(reason.rawValue)): generation=\(progress.generation) "
        + "watermark=\(progress.watermarkId) bootstrap=\(!progress.bootstrapComplete) "
        + "from=\(progress.bootstrapNextStart)")

    var pages = 0
    var offset = progress.bootstrapComplete ? 0 : progress.bootstrapNextStart
    var newestSeen: Int64 = 0

    await publishState(key, phase: .importing(page: 1))
    while true {
      await Task.yield()

      let start = progress.bootstrapComplete ? offset : max(0, offset - Self.pageOverlap)
      // An incremental run usually finds a handful of new plays on its first
      // page; a full page would be fetched for nothing.
      let size = progress.bootstrapComplete && pages == 0 ? Self.firstPageSize : Self.pageSize
      let page: (rows: [ScrobbleRow], total: Int?)
      do {
        page = try await withCheckedThrowingContinuation { continuation in
          AlbumService.shared.getScrobblePage(start: start, end: start + size) {
            continuation.resume(with: $0)
          }
        }
      } catch {
        guard isCurrent(key) else { return }
        await publishState(key, phase: .failed(Self.shortReason(error)), pages: pages)
        return
      }
      guard isCurrent(key) else { return }
      pages += 1

      // The newest row lower than everything already mirrored: the server's
      // log was reset or restored, so its ids mean something else now.
      if progress.bootstrapComplete, pages == 1,
        (page.rows.first?.id ?? 0) < progress.watermarkId
      {
        debugLog("history import: server log reset, rebuilding")
        progress = await CoreDataManager.shared.performBackground { context in
          Self.loadProgress(for: key, reset: true, in: context)
        }
        offset = 0
        continue
      }

      newestSeen = max(newestSeen, page.rows.first?.id ?? 0)
      let isShort = page.rows.count < size
      let reachedWatermark = page.rows.last.map { $0.id <= progress.watermarkId } ?? true
      let done = progress.bootstrapComplete ? isShort || reachedWatermark : isShort
      let now = Date()

      let result = await CoreDataManager.shared.performBackground {
        [progress, newestSeen] context in
        Self.commit(
          page.rows, total: page.total, start: start, done: done, newestSeen: newestSeen,
          key: key, progress: progress, index: index, now: now, in: context)
      }
      guard let result else {
        await publishState(key, phase: .failed("could not save"), pages: pages)
        return
      }
      progress = result.progress
      offset = start + page.rows.count

      debugLog(
        "history import: page \(pages) start=\(start) rows=\(page.rows.count) "
          + "new=\(result.inserted) matched=\(result.matched) total=\(page.total ?? -1)")

      var state = result.state
      state.pages = pages
      if done {
        state.phase = .complete
        await publish(state)
        return
      }
      state.phase = .importing(page: pages + 1)
      await publish(state)

      // FLO_DEBUG_HISTORY_PAGE_DELAY=<s> leaves time to interrupt a bootstrap.
      #if DEBUG
        if let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_HISTORY_PAGE_DELAY"]
          .flatMap(Double.init)
        {
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      #endif
    }
  }

  /// Whether the run may still write for `key`: not cancelled, same login.
  private func isCurrent(_ key: String) -> Bool {
    !Task.isCancelled && AuthService.shared.accountKey == key
  }

  private static func shortReason(_ error: Error) -> String {
    let text = ((error as? AFError)?.underlyingError ?? error).localizedDescription
    return text.count > 60 ? String(text.prefix(59)) + "…" : text
  }

  // MARK: - Core Data (background context only)

  private static func stateEntity(
    for key: String, in context: NSManagedObjectContext
  ) -> HistorySyncStateEntity? {
    let request = NSFetchRequest<HistorySyncStateEntity>(entityName: "HistorySyncStateEntity")
    request.predicate = NSPredicate(format: "accountKey == %@", key)
    request.fetchLimit = 1
    return (try? context.fetch(request))?.first
  }

  /// The account's progress, created on first use. A reset, or aggregates
  /// folded by another version, starts a new generation: the next page wipes
  /// the mirror and the aggregates of older generations.
  private static func loadProgress(
    for key: String, reset: Bool, in context: NSManagedObjectContext
  ) -> Progress {
    let state =
      stateEntity(for: key, in: context)
      ?? {
        let state = HistorySyncStateEntity(context: context)
        state.accountKey = key
        state.aggregateVersion = aggregateVersion
        return state
      }()

    if reset || state.aggregateVersion != aggregateVersion {
      state.generation = state.generation == .max ? 0 : state.generation + 1
      state.aggregateVersion = aggregateVersion
      state.watermarkId = 0
      state.bootstrapComplete = false
      state.bootstrapNextStart = 0
      state.importedCount = 0
      state.matchedCount = 0
      state.earliestPlayAt = nil
      state.lastImportAt = nil
    }
    if context.hasChanges { try? context.save() }

    return Progress(
      generation: state.generation, watermarkId: state.watermarkId,
      bootstrapComplete: state.bootstrapComplete,
      bootstrapNextStart: Int(state.bootstrapNextStart))
  }

  /// Mirrors the page's new rows, folds the matched ones into the aggregates
  /// and records the progress, all in one save. Nil when the save failed or
  /// a rebuild or logout replaced the generation meanwhile.
  private static func commit(
    _ rows: [ScrobbleRow], total: Int?, start: Int, done: Bool, newestSeen: Int64,
    key: String, progress: Progress, index: SmartPlaybackService.LibraryIndex, now: Date,
    in context: NSManagedObjectContext
  ) -> PageResult? {
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    guard let state = stateEntity(for: key, in: context), state.generation == progress.generation
    else { return nil }

    // The first page of a generation replaces what the previous one left.
    if !progress.bootstrapComplete, progress.bootstrapNextStart == 0 {
      let byAccount = NSPredicate(format: "accountKey == %@", key)
      batchDelete("PlayEntity", byAccount, in: context)
      batchDelete(
        "AffinityEntity",
        NSPredicate(format: "accountKey == %@ AND generation != %d", key, progress.generation),
        in: context)
    }

    let existingRequest = NSFetchRequest<NSDictionary>(entityName: "PlayEntity")
    existingRequest.resultType = .dictionaryResultType
    existingRequest.propertiesToFetch = ["serverScrobbleId"]
    existingRequest.predicate = NSPredicate(
      format: "accountKey == %@ AND serverScrobbleId IN %@", key, rows.map(\.id))
    var seen = Set(
      ((try? context.fetch(existingRequest)) ?? []).compactMap {
        ($0["serverScrobbleId"] as? NSNumber)?.int64Value
      })

    var folds: [Fold] = []
    var inserted = 0
    var matched = 0
    var earliest = state.earliestPlayAt

    for row in rows where seen.insert(row.id).inserted {
      let time = Date(timeIntervalSince1970: TimeInterval(row.submissionTime))
      let play = PlayEntity(context: context)
      play.accountKey = key
      play.serverScrobbleId = row.id
      let mediaFileId = row.mediaFileId ?? ""
      play.mediaFileId = mediaFileId
      play.submissionTime = time
      inserted += 1
      earliest = min(earliest ?? time, time)

      guard let song = index.songs[mediaFileId] else { continue }
      matched += 1
      // A play stamped in the future counts as played now.
      let at = min(time, now)
      folds.append(Fold(kind: .song, key: mediaFileId, time: at, weight: 1))
      if !song.artistKey.isEmpty {
        folds.append(Fold(kind: .artist, key: song.artistKey, time: at, weight: 1))
      }
      if !song.albumId.isEmpty {
        folds.append(Fold(kind: .album, key: song.albumId, time: at, weight: 1))
      }
      for genre in song.genres {
        folds.append(
          Fold(kind: .genre, key: genre, time: at, weight: 1 / Double(song.genres.count)))
      }
      if let era = song.era {
        folds.append(Fold(kind: .era, key: era, time: at, weight: 1))
      }
    }

    apply(folds, key: key, generation: progress.generation, in: context)

    state.importedCount += Int64(inserted)
    state.matchedCount += Int64(matched)
    state.earliestPlayAt = earliest
    if let total { state.serverTotal = Int64(total) }

    if progress.bootstrapComplete {
      // Every id above the old watermark is covered only now.
      if done {
        state.watermarkId = max(state.watermarkId, newestSeen)
        state.lastImportAt = now
      }
    } else if done {
      state.bootstrapComplete = true
      state.bootstrapNextStart = 0
      state.watermarkId = newestMirroredId(key: key, in: context) ?? 0
      state.lastImportAt = now
    } else {
      state.bootstrapNextStart = Int64(start + rows.count)
    }

    do {
      try context.save()
    } catch {
      debugLog("history import: save failed: \(error.localizedDescription)")
      return nil
    }

    return PageResult(
      state: importState(of: state),
      progress: Progress(
        generation: state.generation, watermarkId: state.watermarkId,
        bootstrapComplete: state.bootstrapComplete,
        bootstrapNextStart: Int(state.bootstrapNextStart)),
      inserted: inserted, matched: matched)
  }

  private struct Fold {
    let kind: AffinitySnapshot.Kind
    let key: String
    let time: Date
    let weight: Double
  }

  /// Folds each play of weight q at time t into (W, r) with half-life H:
  /// r' = max(r, t), W' = W·2^(−(r'−r)/H) + q·2^(−(r'−t)/H).
  private static func apply(
    _ folds: [Fold], key: String, generation: Int16, in context: NSManagedObjectContext
  ) {
    guard !folds.isEmpty else { return }

    let request = NSFetchRequest<AffinityEntity>(entityName: "AffinityEntity")
    request.predicate = NSPredicate(
      format: "accountKey == %@ AND generation == %d AND key IN %@", key, generation,
      Array(Set(folds.map(\.key))))
    var entities: [String: AffinityEntity] = [:]
    for entity in (try? context.fetch(request)) ?? [] {
      entities["\(entity.kind)|\(entity.key ?? "")"] = entity
    }

    for fold in folds {
      let id = "\(fold.kind.rawValue)|\(fold.key)"
      let entity =
        entities[id]
        ?? {
          let entity = AffinityEntity(context: context)
          entity.accountKey = key
          entity.generation = generation
          entity.kind = fold.kind.rawValue
          entity.key = fold.key
          entity.weight = 0
          entity.referenceTime = fold.time
          entities[id] = entity
          return entity
        }()

      let reference = entity.referenceTime ?? fold.time
      let newReference = max(reference, fold.time)
      entity.weight =
        entity.weight * decay(newReference.timeIntervalSince(reference))
        + fold.weight * decay(newReference.timeIntervalSince(fold.time))
      entity.referenceTime = newReference
      entity.lastPlayAt = max(entity.lastPlayAt ?? fold.time, fold.time)
      entity.plays += 1
    }
  }

  private static func decay(_ age: TimeInterval) -> Double {
    exp2(-max(0, age) / halfLife)
  }

  private static func newestMirroredId(key: String, in context: NSManagedObjectContext) -> Int64? {
    let request = NSFetchRequest<PlayEntity>(entityName: "PlayEntity")
    request.predicate = NSPredicate(format: "accountKey == %@", key)
    request.sortDescriptors = [NSSortDescriptor(key: "serverScrobbleId", ascending: false)]
    request.fetchLimit = 1
    return (try? context.fetch(request))?.first?.serverScrobbleId
  }

  private static func batchDelete(
    _ entityName: String, _ predicate: NSPredicate, in context: NSManagedObjectContext
  ) {
    let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
    fetch.predicate = predicate
    _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: fetch))
  }

  private static func importState(of state: HistorySyncStateEntity) -> ImportState {
    var result = ImportState()
    result.phase = state.bootstrapComplete ? .complete : .idle
    result.serverTotal = Int(state.serverTotal)
    result.importedCount = Int(state.importedCount)
    result.matchedCount = Int(state.matchedCount)
    result.earliestPlayAt = state.earliestPlayAt
    result.lastImportAt = state.lastImportAt
    result.watermarkId = state.watermarkId
    result.bootstrapComplete = state.bootstrapComplete
    return result
  }

  // MARK: - Reading

  /// The aggregates of the newest generation that has any, decayed to now.
  func snapshot() async -> AffinitySnapshot {
    guard let key = AuthService.shared.accountKey else { return AffinitySnapshot() }
    let now = Date()

    return await CoreDataManager.shared.performBackground { context in
      var snapshot = AffinitySnapshot()
      guard let state = Self.stateEntity(for: key, in: context) else { return snapshot }
      snapshot.state = Self.importState(of: state)

      let request = NSFetchRequest<AffinityEntity>(entityName: "AffinityEntity")
      request.predicate = NSPredicate(format: "accountKey == %@", key)
      let rows = (try? context.fetch(request)) ?? []
      // Until a rebuild's first page lands, only the old generation exists.
      let generation =
        rows.contains { $0.generation == state.generation }
        ? state.generation : rows.map(\.generation).max()

      for row in rows where row.generation == generation {
        guard let kind = AffinitySnapshot.Kind(rawValue: row.kind), let rowKey = row.key else {
          continue
        }
        let reference = row.referenceTime ?? now
        snapshot.aggregates[kind, default: [:]][rowKey] = AffinitySnapshot.Aggregate(
          weight: row.weight * Self.decay(now.timeIntervalSince(reference)),
          lastPlayAt: row.lastPlayAt, plays: Int(row.plays))
      }

      let future = NSFetchRequest<PlayEntity>(entityName: "PlayEntity")
      future.predicate = NSPredicate(
        format: "accountKey == %@ AND submissionTime > %@", key, now as NSDate)
      snapshot.futurePlays = (try? context.count(for: future)) ?? 0
      return snapshot
    }
  }

  // MARK: - Publishing

  /// Publishes the stored state of `key` with `phase`.
  private func publishState(_ key: String, phase: ImportState.Phase, pages: Int = 0) async {
    if case .failed = phase { lastFailedAt = Date() }
    var state = await CoreDataManager.shared.performBackground { context in
      Self.stateEntity(for: key, in: context).map(Self.importState(of:)) ?? ImportState()
    }
    state.phase = phase
    state.pages = pages
    await publish(state)
  }

  private func publish(_ state: ImportState) async {
    await MainActor.run { HistoryStatus.shared.state = state }
  }

  /// Loads the stored state for the diagnostics screen, unless a run is
  /// already publishing its own or the last run's failure is still showing.
  func publishStoredState() async {
    guard run == nil, let key = AuthService.shared.accountKey,
      !CoreDataManager.shared.isUsingVolatileStore
    else { return }
    switch await MainActor.run(body: { HistoryStatus.shared.state.phase }) {
    case .failed, .skipped: return
    default: break
    }
    let state = await CoreDataManager.shared.performBackground { context in
      Self.stateEntity(for: key, in: context).map(Self.importState(of:))
    }
    if let state { await publish(state) }
  }
}
