import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class HandoffTests: XCTestCase {
  private func entry(_ id: String, title: String? = nil) -> QueueEntry {
    QueueEntry(song: .fixture(id, title: title), contextName: "Album", isFromPlaylist: false)
  }

  private func snapshot(_ entries: [QueueEntry], active: Int = 0) -> QueueSnapshot {
    QueueSnapshot(
      entries: entries, activeIndex: active, position: 73.5, qualified: false, listened: 41,
      playbackMode: PlaybackMode.repeatAlbum)
  }

  func testHandoffMessagesSurviveTheTrip() {
    let handoff = Link.Handoff(
      id: UUID(), accountKey: "music.lan|id", snapshot: snapshot([entry("a"), entry("b")]))
    let messages: [Link.Message] = [
      .play(handoff), .handoffResult(id: handoff.id, result: .started),
      .handoffResult(id: handoff.id, result: .ready),
      .handoffResult(id: handoff.id, result: .failed("Something else started on the watch.")),
    ]
    for message in messages {
      XCTAssertEqual(Link.decode(Link.Message.self, from: Link.encode(message)), message)
    }
    for reply in [Link.Reply.unavailable, .notSignedIn] {
      XCTAssertEqual(Link.decode(Link.Reply.self, from: Link.encode(reply)), reply)
    }
  }

  /// The message and reply types of a build before handoffs.
  private enum OldMessage: Codable {
    case signIn(Link.SignIn)
    case signInFailed(String)
  }

  private enum OldReply: Codable {
    case accepted
    case alreadySignedIn
    case otherAccount(user: String, host: String)
  }

  /// An older build reads a handoff and its answers as nothing, so it
  /// answers with an empty reply instead of a wrong one; the newer fields of
  /// the states it leaves out read as nil here.
  func testOlderBuildsReadHandoffsAsNothing() throws {
    let handoff = Link.Handoff(id: UUID(), accountKey: "k", snapshot: snapshot([entry("a")]))
    XCTAssertNil(Link.decode(OldMessage.self, from: Link.encode(Link.Message.play(handoff))))
    XCTAssertNil(Link.decode(OldReply.self, from: Link.encode(Link.Reply.unavailable)))
    XCTAssertNil(Link.decode(Link.Message.self, from: ["payload": Data(#"{"later":{}}"#.utf8)]))

    let olderWatch = #"""
      {"downloadBitRate":"192","collections":[],"incoming":{},"musicBytes":0,"freeBytes":0}
      """#
    let watch = try XCTUnwrap(
      Link.decode(Link.WatchState.self, from: ["payload": Data(olderWatch.utf8)]))
    XCTAssertNil(watch.handoff)
    let olderPhone = #"""
      {"share":true,"streamingBitRate":"192","downloadBitRate":"0","keepPlaying":true,"sending":{}}
      """#
    let phone = try XCTUnwrap(
      Link.decode(Link.PhoneState.self, from: ["payload": Data(olderPhone.utf8)]))
    XCTAssertNil(phone.handoff)
    XCTAssertNil(phone.syncQueue)
  }

  func testReplyMessagesNameTheOtherDevice() {
    XCTAssertNil(Link.handoffMessage(.accepted, peer: .watch))
    XCTAssertEqual(
      Link.handoffMessage(.unavailable, peer: .iPhone),
      "The song cannot play on your iPhone right now.")
    XCTAssertEqual(
      Link.handoffMessage(.otherAccount(user: "v", host: "music.lan"), peer: .iPhone),
      "Your iPhone is signed in as v on music.lan. Log out there first.")
    XCTAssertEqual(Link.handoffMessage(nil, peer: .watch), "The watch did not answer.")
  }

  /// Long titles in other scripts count by their encoded bytes; the songs
  /// after the current one are cut from the end, repeats kept.
  func testSnapshotFitsItsBudget() throws {
    let title = String(repeating: "Ünïcødé 歌 🎵 ", count: 20)
    let ids = (0..<120).map { "s\($0 % 7)" }
    let full = snapshot(ids.map { entry($0, title: title) })
    let budget = 48_000
    let trimmed = try XCTUnwrap(full.trimmed(toFit: budget))

    XCTAssertLessThanOrEqual(try JSONEncoder().encode(trimmed).count, budget)
    XCTAssertGreaterThan(trimmed.entries.count, 1)
    XCTAssertLessThan(trimmed.entries.count, ids.count)
    XCTAssertEqual(trimmed.entries, Array(full.entries.prefix(trimmed.entries.count)))
    var oneMore = trimmed
    oneMore.entries.append(full.entries[trimmed.entries.count])
    XCTAssertGreaterThan(try JSONEncoder().encode(oneMore).count, budget)

    XCTAssertEqual(full.trimmed(toFit: 10_000_000), full)
    XCTAssertNil(snapshot(full.entries, active: 100).trimmed(toFit: budget))
  }

  func testQueueRowsKeepWhatTheQueueNeeds() {
    let service = PlaybackService(context: CoreDataManager.inMemoryContainer().viewContext)
    let song = Song.fixture("s1", mediaFileId: "m1")
    let entity = service.makeEntry(song: song, context: "Liked Songs", isFromPlaylist: true)
    let entry = QueueEntry(entity)
    XCTAssertEqual(entry.song.playbackID, "m1")
    XCTAssertEqual(entry.song.title, song.title)
    XCTAssertEqual(entry.contextName, "Liked Songs")
    XCTAssertTrue(entry.isFromPlaylist)
    let again = service.makeEntry(
      song: entry.song, context: entry.contextName, isFromPlaylist: entry.isFromPlaylist)
    XCTAssertEqual(QueueEntry(again), entry)
  }

  func testCanStartLocalOrStreamableSongs() {
    let queue = snapshot([entry("a"), entry("b")], active: 1)
    let start = { (local: Set<String>, streaming: Bool, reachable: Bool) in
      PlayerViewModel.canStart(
        queue, localIds: local, streamingAllowed: streaming, serverReachable: reachable)
    }
    XCTAssertTrue(start(["b"], false, false))
    XCTAssertFalse(start(["a"], false, true))
    XCTAssertTrue(start([], true, true))
    XCTAssertFalse(start([], true, false))
    XCTAssertFalse(start([], false, true))
    XCTAssertFalse(
      PlayerViewModel.canStart(
        snapshot([entry("a")], active: 3), localIds: ["a"], streamingAllowed: true,
        serverReachable: true))
  }

  /// Only the attempt's own start pauses, and only while the start
  /// generation is what was sent and the user did not skip; anything else
  /// keeps the song here.
  func testSenderPausesOnlyForItsOwnStart() {
    let id = UUID()
    let attempt = HandoffAttempt(id: id, startGeneration: 4)
    let step = { (result: Link.HandoffResult, id: UUID, generation: Int) in
      attempt.step(for: result, id: id, startGeneration: generation, skipped: false)
    }
    XCTAssertEqual(step(.started, id, 4), .pause)
    XCTAssertEqual(step(.started, UUID(), 4), .ignore)
    XCTAssertEqual(step(.ready, UUID(), 4), .ignore)
    XCTAssertEqual(step(.started, id, 5), .keepPlaying)
    XCTAssertEqual(step(.ready, id, 4), .keepPlaying)
    XCTAssertEqual(step(.failed("no"), id, 4), .keepPlaying)
  }

  /// A skip on the sender meanwhile, which moves no start generation, keeps
  /// the song skipped to playing; a song that ended on its own and moved on,
  /// or Keep Playing after it, still gives way.
  func testSkipOnTheSenderKeepsPlaying() {
    let id = UUID()
    let attempt = HandoffAttempt(id: id, startGeneration: 4)
    let step = { (skipped: Bool) in
      attempt.step(for: .started, id: id, startGeneration: 4, skipped: skipped)
    }
    XCTAssertEqual(step(true), .keepPlaying)
    XCTAssertEqual(step(false), .pause)
  }

  /// A result counts once, also after the wait for it ended; a copy of it
  /// and the result of an older attempt change nothing.
  func testLateResultCountsOnce() {
    let first = HandoffAttempt(id: UUID(), startGeneration: 1)
    let second = HandoffAttempt(id: UUID(), startGeneration: 2)
    var attempts = HandoffAttempts()
    attempts.begin(first)
    XCTAssertNil(attempts.take(second.id))
    attempts.expire(first.id)
    XCTAssertNil(attempts.current)
    XCTAssertEqual(attempts.take(first.id), first)
    XCTAssertNil(attempts.take(first.id))

    attempts.begin(first)
    attempts.expire(first.id)
    attempts.begin(second)
    XCTAssertNil(attempts.take(first.id))
    XCTAssertEqual(attempts.take(second.id), second)

    attempts.begin(first)
    attempts.expire(first.id)
    attempts.clear()
    XCTAssertNil(attempts.take(first.id))
  }

  /// The receiver reports a start only for the queue handed over; anything
  /// started there meanwhile fails the handoff, heard or not.
  func testReceiverReportsOnlyTheHandedOverQueue() {
    let result = { (outcome: StartOutcome, adopted: Bool) in
      HandoffReceiver.result(outcome, stillAdopted: adopted, here: .watch)
    }
    XCTAssertEqual(result(.heard, true), .started)
    XCTAssertEqual(result(.silent("start ended"), true), .ready)
    XCTAssertEqual(result(.heard, false), .failed("Something else started on the watch."))
    XCTAssertEqual(
      result(.silent("start ended"), false), .failed("Something else started on the watch."))
  }

  /// The sender stops counting the song it handed over, and counts it again
  /// once that is undone or another song plays.
  func testHandedOverSongStopsCounting() {
    XCTAssertTrue(PlayerViewModel.isHandedOff("a", nowPlaying: "a"))
    XCTAssertFalse(PlayerViewModel.isHandedOff(nil, nowPlaying: "a"))
    XCTAssertFalse(PlayerViewModel.isHandedOff("a", nowPlaying: "b"))
    XCTAssertFalse(PlayerViewModel.isHandedOff(nil, nowPlaying: nil))
  }
}
