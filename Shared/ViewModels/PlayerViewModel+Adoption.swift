//
//  PlayerViewModel+Adoption.swift
//  Ownwave
//

import Foundation

/// A queue row as values, for another device or the server.
struct QueueEntry: Codable, Equatable {
  let song: Song
  /// The collection it came from, which tells its origin (`playbackOrigin`).
  let contextName: String
  let isFromPlaylist: Bool

  init(song: Song, contextName: String, isFromPlaylist: Bool) {
    self.song = song
    self.contextName = contextName
    self.isFromPlaylist = isFromPlaylist
  }

  init(_ entity: QueueEntity) {
    self.init(
      song: Song(from: entity), contextName: entity.contextName ?? "",
      isFromPlaylist: entity.isFromPlaylist)
  }
}

/// The queue in play order, shuffle flattened, where the current song
/// stands and what was heard of it: what a handoff carries and what the
/// server sync saves and offers.
struct QueueSnapshot: Codable, Equatable {
  var entries: [QueueEntry]
  var activeIndex: Int
  /// Seconds into the current song.
  var position: Double
  var qualified: Bool
  var listened: Double
  var playbackMode: String

  /// The snapshot with the entries after the current one cut from the end
  /// until it encodes to at most `budgetBytes`; nil when not even the songs
  /// up to the current one fit.
  func trimmed(toFit budgetBytes: Int) -> QueueSnapshot? {
    let encoder = JSONEncoder()
    var kept = self
    kept.entries = []
    guard var size = try? encoder.encode(kept).count else { return nil }
    for entry in entries {
      // Entries are joined by commas inside the brackets already counted.
      guard let bytes = try? encoder.encode(entry).count,
        size + bytes + (kept.entries.isEmpty ? 0 : 1) <= budgetBytes
      else { break }
      size += bytes + (kept.entries.isEmpty ? 0 : 1)
      kept.entries.append(entry)
    }
    return kept.entries.indices.contains(activeIndex) ? kept : nil
  }
}

/// How an adopted start went: heard through an output, or over without a
/// sound (the activation failed, the device list was dismissed, a pause
/// ended it, or nothing played in time), with the reason.
enum StartOutcome: Equatable {
  case heard
  case silent(String)
}

/// The outcome of one adopted start, for whoever waits for it. Used on the
/// main queue only, like the player.
final class StartWatch {
  private(set) var outcome: StartOutcome?
  private var waiters: [CheckedContinuation<StartOutcome, Never>] = []

  func finish(_ outcome: StartOutcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    waiters.forEach { $0.resume(returning: outcome) }
    waiters = []
  }

  func wait() async -> StartOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { waiters.append($0) }
  }
}

// Taking over a queue from another device or the server, and handing the
// current one over.
extension PlayerViewModel {
  /// The queue from the current song on, so Previous on the other device
  /// starts at the song handed over, within `budgetBytes` of JSON; nil for a
  /// radio station or an empty queue.
  func snapshot(budgetBytes: Int) -> QueueSnapshot? {
    guard nowPlaying != nil, !isLiveRadio else { return nil }
    return QueueSnapshot(
      entries: queue[activeQueueIdx...].map(QueueEntry.init), activeIndex: 0,
      position: currentPosition, qualified: hasQualified, listened: secondsListened,
      playbackMode: playbackMode
    ).trimmed(toFit: budgetBytes)
  }

  /// Whether the current song of `snapshot` can start here: it is on the
  /// device, or it may stream and the server answers.
  static func canStart(
    _ snapshot: QueueSnapshot, localIds: Set<String>, streamingAllowed: Bool,
    serverReachable: Bool
  ) -> Bool {
    guard snapshot.entries.indices.contains(snapshot.activeIndex) else { return false }
    return localIds.contains(snapshot.entries[snapshot.activeIndex].song.playbackID)
      || (streamingAllowed && serverReachable)
  }

  /// Makes `snapshot` the queue, paused at its position with its listening
  /// carried over, and plays it when `play`. False for a snapshot that does
  /// not hold together or a queue that could not be stored; the old queue
  /// stays then, paused. Writes no journal row.
  @discardableResult
  func adoptQueue(_ snapshot: QueueSnapshot, play: Bool) -> Bool {
    guard snapshot.entries.indices.contains(snapshot.activeIndex), snapshot.position.isFinite,
      snapshot.position >= 0
    else { return false }
    // Unconditionally: an activation still under way is not playing yet, and
    // its answer, a mix being built or a Keep Playing continuation must not
    // start the old queue later.
    pause()
    beginUserStart()
    let entities = snapshot.entries.map {
      PlaybackService.shared.makeEntry(
        song: $0.song, context: $0.contextName, isFromPlaylist: $0.isFromPlaylist)
    }
    guard PlaybackService.shared.store(order: entities) else { return false }
    userStarts += 1
    replaceQueue(entities, at: snapshot.activeIndex)
    let modes = [PlaybackMode.defaultPlayback, PlaybackMode.repeatAlbum, PlaybackMode.repeatOnce]
    setPlaybackMode(
      modes.contains(snapshot.playbackMode) ? snapshot.playbackMode : PlaybackMode.defaultPlayback)
    isFinished = false
    isMediaFailed = false
    isStreamingBlocked = false
    let duration = entities[snapshot.activeIndex].duration
    progress = duration > 0 ? min(max(snapshot.position / duration, 0), 1) : 0
    setNowPlaying(playAudio: false)
    carryOverListening(qualified: snapshot.qualified, listened: snapshot.listened)
    UserDefaultsManager.nowPlayingProgress = progress
    queueEvents.send(.synced)
    // The pause above ended any earlier adopted start.
    if play {
      startWatch = StartWatch()
      self.play()
    }
    return true
  }

  /// How the start of the last adopted queue goes; silent when nothing was
  /// heard within `limit`, or when no adopted start is under way.
  @MainActor func startOutcome(within limit: Duration = .seconds(25)) async -> StartOutcome {
    guard let watch = startWatch else { return .silent("no start under way") }
    let deadline = Task { @MainActor [weak self] in
      guard (try? await Task.sleep(for: limit)) != nil else { return }
      if self?.startWatch === watch { self?.startWatch = nil }
      watch.finish(.silent("nothing heard within \(limit.components.seconds) s"))
    }
    let outcome = await watch.wait()
    deadline.cancel()
    return outcome
  }

  /// Ends the adopted start under way, if any, with `outcome`.
  func finishStartWatch(_ outcome: StartOutcome) {
    guard let watch = startWatch else { return }
    startWatch = nil
    watch.finish(outcome)
  }

  /// The current song went to the other device: this one stops counting it,
  /// starts nothing that was pending, and what the server holds is no
  /// longer this device's to save.
  func handOff() {
    dropPendingStarts()
    skippedSinceHandOff = false
    handedOffSongId = nowPlayingId
    queueEvents.send(.synced)
  }

  /// The other device did not take over: the song counts here again, and
  /// the queue is this device's to save again.
  func handOffEnded() {
    handedOffSongId = nil
    queueEvents.send(.changed)
  }

  /// Whether the current song was handed over to the other device.
  var isHandedOff: Bool {
    Self.isHandedOff(handedOffSongId, nowPlaying: nowPlayingId)
  }

  static func isHandedOff(_ handedOffSongId: String?, nowPlaying: String?) -> Bool {
    handedOffSongId != nil && handedOffSongId == nowPlaying
  }
}
