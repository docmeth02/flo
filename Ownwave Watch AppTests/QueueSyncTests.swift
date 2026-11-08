import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class QueueSyncTests: XCTestCase {
  func testSavesOnlyWhatChangedHere() {
    var rules = QueueSaveRules()
    XCTAssertEqual(rules.handle(.paused), .none)
    XCTAssertEqual(rules.handle(.resignedActive), .none)
    XCTAssertEqual(rules.handle(.advanced), .none)
    XCTAssertEqual(rules.handle(.paused), .saveNow)
    XCTAssertEqual(rules.handle(.resignedActive), .none)

    XCTAssertEqual(rules.handle(.changed), .schedule)
    XCTAssertEqual(rules.debounceEnded(), .saveNow)
    XCTAssertEqual(rules.debounceEnded(), .none)
  }

  /// A pauses and saves, B saves its own, A leaves the foreground: A's
  /// unchanged queue does not overwrite B's.
  func testAnotherDevicesSaveStays() {
    var a = QueueSaveRules()
    var b = QueueSaveRules()
    _ = a.handle(.advanced)
    XCTAssertEqual(a.handle(.paused), .saveNow)
    _ = b.handle(.changed)
    XCTAssertEqual(b.handle(.paused), .saveNow)
    XCTAssertEqual(a.handle(.resignedActive), .none)
  }

  /// A failed save is not retried; the next event saves the queue afresh.
  func testFailedSaveWaitsForTheNextEvent() {
    var rules = QueueSaveRules()
    _ = rules.handle(.advanced)
    XCTAssertEqual(rules.handle(.paused), .saveNow)
    rules.saveFailed()
    XCTAssertTrue(rules.isDirty)
    XCTAssertEqual(rules.handle(.resignedActive), .saveNow)
  }

  func testAdoptionAndLogoutCancelThePendingSave() {
    var rules = QueueSaveRules()
    XCTAssertEqual(rules.handle(.changed), .schedule)
    XCTAssertEqual(rules.handle(.synced), .cancel)
    XCTAssertEqual(rules.debounceEnded(), .none)
    XCTAssertEqual(rules.handle(.paused), .none)
  }

  private let watch = PlayQueueSync.client(platform: "watchOS")
  private let phone = PlayQueueSync.client(platform: "iOS")

  private func remote(
    _ ids: [String], at index: Int = 0, position: Double = 133, changed: String = "t2",
    by client: String? = nil
  ) -> RemoteQueue {
    RemoteQueue(
      songs: ids.map { Song.fixture($0, mediaFileId: $0) }, currentIndex: index,
      position: position, changed: changed, changedBy: client ?? watch)
  }

  private func decide(
    _ queue: RemoteQueue, playing: Bool = false, handled: String? = "t1",
    tail: [String?] = ["x"], position: Double = 0
  ) -> PlayQueueSync.Decision {
    PlayQueueSync.decide(
      queue, client: phone, account: "k", isPlaying: playing, handled: handled, localTail: tail,
      localPosition: position)
  }

  private func reason(_ decision: PlayQueueSync.Decision) -> PlayQueueSync.NoOffer? {
    if case .none(let reason) = decision { reason } else { nil }
  }

  func testOfferRules() throws {
    guard case .offer(let offer) = decide(remote(["a", "b"], at: 1)) else {
      return XCTFail("no offer")
    }
    XCTAssertEqual(offer.device, "Apple Watch")
    XCTAssertEqual(offer.song.id, "b")
    XCTAssertEqual(offer.snapshot.activeIndex, 1)
    XCTAssertEqual(offer.snapshot.entries.first?.contextName, "Continue from Apple Watch")
    XCTAssertEqual(offer.snapshot.listened, 0)
    XCTAssertFalse(offer.snapshot.qualified)
    XCTAssertEqual(offer.snapshot.playbackMode, PlaybackMode.defaultPlayback)

    XCTAssertEqual(reason(decide(remote(["a"]), playing: true)), .playing)
    XCTAssertEqual(reason(decide(remote([]))), .empty)
    XCTAssertEqual(reason(decide(remote(["a"], by: phone))), .savedHere)
    XCTAssertEqual(reason(decide(remote(["a"], changed: "t1"))), .handled)
    XCTAssertEqual(reason(decide(remote(["a", "b"], at: 2))), .outOfRange)
  }

  /// The same songs from the current one on are offered only when the
  /// position differs by more than 10 s.
  func testSameTailOffersOnlyAnotherPosition() {
    let queue = remote(["z", "a", "b"], at: 1, position: 100)
    XCTAssertEqual(reason(decide(queue, tail: ["a", "b"], position: 92)), .sameAsHere)
    XCTAssertEqual(reason(decide(queue, tail: ["a", "b"], position: 110)), .sameAsHere)
    XCTAssertNil(reason(decide(queue, tail: ["a", "b"], position: 80)))
    XCTAssertNil(reason(decide(queue, tail: ["a"], position: 100)))
  }

  func testDevicesByClientName() {
    XCTAssertEqual(PlayQueueSync.device(phone), "iPhone")
    XCTAssertEqual(PlayQueueSync.device(watch), "Apple Watch")
    XCTAssertEqual(PlayQueueSync.device("feishin"), "feishin")
  }

  func testRemoteQueueFromTheServersAnswer() throws {
    let empty = #"""
      {"subsonic-response":{"status":"ok","playQueueByIndex":
      {"username":"u","changed":"0001-01-01T00:00:00Z","changedBy":""}}}
      """#
    let none = try JSONDecoder().decode(
      SubsonicEnvelope<PlayQueueByIndex>.self, from: Data(empty.utf8))
    XCTAssertTrue(RemoteQueue(none.data).songs.isEmpty)

    let saved = #"""
      {"subsonic-response":{"status":"ok","playQueueByIndex":{"currentIndex":1,"position":12500,
      "changed":"2026-11-08T16:05:47Z","changedBy":"Ownwave iOS","entry":[
      {"id":"s1","title":"One","duration":200},{"id":"s2","title":"Two","duration":180}]}}}
      """#
    let queue = RemoteQueue(
      try JSONDecoder().decode(SubsonicEnvelope<PlayQueueByIndex>.self, from: Data(saved.utf8))
        .data)
    XCTAssertEqual(queue.songs.map(\.playbackID), ["s1", "s2"])
    XCTAssertEqual(queue.currentIndex, 1)
    XCTAssertEqual(queue.position, 12.5)
    XCTAssertEqual(queue.changedBy, phone)
  }

  /// Repeated ids in the form, the client name the only change to the
  /// credentials, whose encoded "+" stays.
  func testSaveRequestBytes() throws {
    let entries = ["s1", "s2", "s1"].map {
      QueueEntry(song: .fixture($0, mediaFileId: $0), contextName: "A", isFromPlaylist: false)
    }
    let snapshot = QueueSnapshot(
      entries: entries, activeIndex: 1, position: 12.4996, qualified: true, listened: 8,
      playbackMode: PlaybackMode.defaultPlayback)
    let request = try PlayQueueSync.saveRequest(
      snapshot, server: "https://music.lan/nd",
      credentials: "?u=a%2Bb&t=tok&s=salt&v=1.16.1&c=Ownwave&f=json", client: phone)

    XCTAssertEqual(request.httpMethod, "POST")
    let url = try XCTUnwrap(request.url?.absoluteString)
    XCTAssertEqual(
      url,
      "https://music.lan/nd/rest/savePlayQueueByIndex"
        + "?u=a%2Bb&t=tok&s=salt&v=1.16.1&c=Ownwave%20iOS&f=json")
    XCTAssertEqual(url.components(separatedBy: "c=").count, 2)
    let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    XCTAssertEqual(body, "id=s1&id=s2&id=s1&currentIndex=1&position=12500")
  }
}
