//
//  Handoff.swift
//  Ownwave
//

import Combine
import Foundation

/// A handoff this device sent, and what its result means here.
struct HandoffAttempt: Equatable {
  let id: UUID
  /// The player's start generation, queue and song when it was sent.
  let startGeneration: Int
  let queueIds: [String?]
  let songId: String?

  enum Step: Equatable {
    /// The other device plays the queue that was sent: this one pauses.
    case pause
    /// The song stays here and counts here again.
    case keepPlaying
    /// Not this attempt's result.
    case ignore
  }

  /// Pauses only for `.started` while the player still plays the song and
  /// the queue it sent and started nothing since: a late result never
  /// pauses what the user started or skipped to meanwhile.
  func step(
    for result: Link.HandoffResult, id: UUID, startGeneration: Int, queueIds: [String?],
    songId: String?
  ) -> Step {
    guard id == self.id else { return .ignore }
    guard result == .started, startGeneration == self.startGeneration,
      queueIds == self.queueIds, songId == self.songId
    else { return .keepPlaying }
    return .pause
  }
}

/// Sends the current queue to the other device (Play on Watch, Play on
/// iPhone) and follows the attempt until its result. Each link owns one.
@MainActor final class HandoffSender: ObservableObject {
  enum Phase: Equatable {
    case idle, sending, started, ready
    case failed(String)
  }

  @Published private(set) var phase = Phase.idle
  let peer: Link.Peer

  private var attempt: HandoffAttempt?
  private weak var player: PlayerViewModel?
  private var sentAt = Date()
  private var deadline: Task<Void, Never>?
  private var settle: Task<Void, Never>?

  /// How long the other device has to say how its start went.
  static let resultTimeout: Duration = .seconds(30)
  /// How long a final phase shows before the sender is idle again.
  static let phaseShown: Duration = .seconds(4)

  init(to peer: Link.Peer) {
    self.peer = peer
  }

  /// What a final phase says: "Playing on the watch", "Ready on your
  /// iPhone", or why the other device did not take over.
  var message: String? {
    switch phase {
    case .idle, .sending: nil
    case .started: "Playing on \(peer.name)"
    case .ready: "Ready on \(peer.name)"
    case .failed(let reason): reason
    }
  }

  /// Ends at once with `reason`, for a check the link makes before sending;
  /// a handoff under way goes on.
  func refuse(_ reason: String) {
    guard phase != .sending else { return }
    finish(.failed(reason))
  }

  /// Hands the player's queue over through `transmit`, which sends the
  /// message and returns the other device's reply. Nothing while a handoff
  /// is under way.
  func send(_ player: PlayerViewModel, transmit: (Link.Message) async throws -> Link.Reply?) async {
    guard phase != .sending else { return }
    guard let account = AuthService.shared.accountKey,
      let snapshot = player.snapshot(budgetBytes: Link.handoffBudget)
    else { return refuse("Nothing is playing to hand over.") }
    let handoff = Link.Handoff(id: UUID(), accountKey: account, snapshot: snapshot)
    // First: it moves the start generation the attempt records.
    player.handOff()
    let attempt = HandoffAttempt(
      id: handoff.id, startGeneration: player.startGeneration, queueIds: player.queue.map(\.id),
      songId: player.nowPlayingId)
    self.attempt = attempt
    self.player = player
    sentAt = Date()
    settle?.cancel()
    phase = .sending
    let bytes = (try? JSONEncoder().encode(Link.Message.play(handoff)))?.count ?? 0
    RequestLog.shared.trace(
      "handoff \(Self.short(handoff.id)) sent \(snapshot.entries.count) entries \(bytes) bytes")

    let reply: Link.Reply?
    do {
      reply = try await transmit(.play(handoff))
    } catch {
      return fail(attempt.id, error.localizedDescription)
    }
    // A logout or a newer attempt took its place.
    guard self.attempt?.id == attempt.id else { return }
    if let reason = Link.handoffMessage(reply, peer: peer) { return fail(attempt.id, reason) }
    RequestLog.shared.trace("handoff \(Self.short(attempt.id)) accepted")
    deadline = Task { [weak self] in
      guard (try? await Task.sleep(for: Self.resultTimeout)) != nil, let self else { return }
      self.fail(attempt.id, "\(self.peer.title) did not start playing.")
    }
  }

  /// The other device's result; late and repeated ones change nothing.
  func received(id: UUID, result: Link.HandoffResult) {
    guard let attempt, let player else { return }
    let step = attempt.step(
      for: result, id: id, startGeneration: player.startGeneration,
      queueIds: player.queue.map(\.id), songId: player.nowPlayingId)
    guard step != .ignore else { return }
    if case .failed(let reason) = result { return fail(id, reason) }
    let seconds = Int(Date().timeIntervalSince(sentAt))
    RequestLog.shared.trace(
      "handoff \(Self.short(id)) \(result == .started ? "started" : "ready") after \(seconds) s")
    if step == .pause { player.pause() } else { player.handOffEnded() }
    finish(result == .started ? .started : .ready)
  }

  /// A logout drops the attempt; its result comes for the old account.
  func cancel() {
    guard attempt != nil else { return }
    player?.handOffEnded()
    finish(.idle)
  }

  private func fail(_ id: UUID, _ reason: String) {
    guard attempt?.id == id else { return }
    RequestLog.shared.trace("handoff \(Self.short(id)) failed: \(reason)")
    player?.handOffEnded()
    finish(.failed(reason))
  }

  private func finish(_ phase: Phase) {
    attempt = nil
    deadline?.cancel()
    self.phase = phase
    settle?.cancel()
    guard phase != .idle else { return }
    settle = Task { [weak self] in
      guard (try? await Task.sleep(for: Self.phaseShown)) != nil else { return }
      self?.phase = .idle
    }
  }

  static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}

/// Takes a queue the other device handed over, for the link that receives
/// it; the player is the app's, or on the watch the one its root view owns.
@MainActor struct HandoffReceiver {
  let player: PlayerViewModel
  /// This device, as the result names it.
  let here: Link.Peer
  /// Runs once the queue is taken, e.g. to show the player.
  var adopted: () -> Void = {}

  /// Adopts and plays the handoff, answers `reply` at once, then sends the
  /// start's result through `send`. A start without sound leaves the queue
  /// paused here.
  func take(
    _ handoff: Link.Handoff, reply: (Link.Reply) -> Void,
    send: @escaping (Link.Message) -> Void
  ) {
    let answer = accept(handoff)
    let label =
      switch answer {
      case .accepted: "accepted"
      case .unavailable: "song unavailable"
      case .notSignedIn: "not signed in"
      case .otherAccount, .alreadySignedIn: "another account"
      }
    RequestLog.shared.trace(
      "handoff \(HandoffSender.short(handoff.id)) received "
        + "\(handoff.snapshot.entries.count) entries: \(label)")
    reply(answer)
    guard answer == .accepted else { return }
    adopted()
    Task {
      let result = await result(of: handoff)
      send(.handoffResult(id: handoff.id, result: result))
    }
  }

  private func accept(_ handoff: Link.Handoff) -> Link.Reply {
    guard let account = AuthService.shared.accountKey else { return .notSignedIn }
    guard account == handoff.accountKey else {
      return .otherAccount(user: ServerAccount.username, host: ServerAccount.host)
    }
    let startable = PlayerViewModel.canStart(
      handoff.snapshot, localIds: DownloadStore.localMediaFileIds(),
      streamingAllowed: TranscodingSettings.streamingBitRate != nil,
      serverReachable: ConnectivityMonitor.shared.canReachServer)
    guard startable, player.adoptQueue(handoff.snapshot, play: true) else { return .unavailable }
    return .accepted
  }

  private func result(of handoff: Link.Handoff) async -> Link.HandoffResult {
    let outcome = await player.startOutcome()
    let result = Self.result(
      outcome,
      stillAdopted: player.queue.map(\.id) == handoff.snapshot.entries.map(\.song.playbackID),
      here: here)
    // Nothing may start it later, a kept start's settle included.
    if result == .ready { player.pause() }
    let reason = if case .silent(let reason) = outcome { ": \(reason)" } else { "" }
    RequestLog.shared.trace("handoff \(HandoffSender.short(handoff.id)) \(result)\(reason)")
    return result
  }

  /// Heard is started and silent is ready, as long as the queue is still the
  /// one handed over: something the user started here meanwhile, or a
  /// logout, fails the handoff, so the sender plays on.
  nonisolated static func result(_ outcome: StartOutcome, stillAdopted: Bool, here: Link.Peer)
    -> Link.HandoffResult
  {
    guard stillAdopted else { return .failed("Something else started on \(here.name).") }
    return outcome == .heard ? .started : .ready
  }
}
