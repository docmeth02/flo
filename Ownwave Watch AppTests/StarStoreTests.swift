import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

@MainActor
final class StarStoreTests: XCTestCase {
  private var reachable = true
  private var answers: [(Result<Void, Error>) -> Void] = []

  private func makeStore(defaults: UserDefaults? = nil) -> StarStore {
    StarStore(
      defaults: defaults ?? makeDefaults(), canSend: { [unowned self] in self.reachable },
      send: { [unowned self] _, _, completion in self.answers.append(completion) })
  }

  /// A song liked offline is still known as a song after a relaunch, so a
  /// liked list that lacks it once the like was taken clears it.
  func testAPendingSongLikeSurvivesARelaunch() async {
    reachable = false
    let defaults = makeDefaults()
    makeStore(defaults: defaults).setSong(true, id: "s1")

    reachable = true
    let store = makeStore(defaults: defaults)
    answers[0](.success(()))
    await settle()
    XCTAssertTrue(store.isStarred("s1", listed: false))

    store.adoptServerStars([], since: store.listRevision)
    XCTAssertFalse(store.isStarred("s1", listed: true))
  }

  /// A confirmation makes an older full list stale, not a song's lookup.
  func testAConfirmationInvalidatesOlderListsOnly() async {
    let store = makeStore()
    store.setSong(true, id: "s1")
    let list = store.listRevision
    let lookup = store.editCount
    answers[0](.success(()))
    await settle()

    store.adoptServerStars([], since: list)
    XCTAssertTrue(store.isStarred("s1", listed: false))
    XCTAssertEqual(store.editCount, lookup)
  }

  func testListedStateWithoutAnEdit() {
    let store = makeStore()
    XCTAssertTrue(store.isStarred("al1", listed: true))
    XCTAssertFalse(store.isStarred("al1", listed: false))
  }

  func testPendingEditWinsOverTheListedState() {
    reachable = false
    let store = makeStore()
    store.set(true, id: "al1")
    XCTAssertTrue(store.isStarred("al1", listed: false))
    XCTAssertTrue(answers.isEmpty)
  }

  func testConfirmedStarWinsOverTheListedState() async {
    let store = makeStore()
    store.set(false, id: "s1")
    answers[0](.success(()))
    await settle()
    XCTAssertFalse(store.isStarred("s1", listed: true))
  }

  func testPendingEditWinsOverAConfirmedStar() async {
    let store = makeStore()
    store.set(true, id: "s1")
    answers[0](.success(()))
    await settle()

    reachable = false
    store.set(false, id: "s1")
    XCTAssertFalse(store.isStarred("s1", listed: true))
  }

  func testFreshServerStateReplacesAnEarlierConfirmation() async {
    let store = makeStore()
    store.set(true, id: "s1")
    answers[0](.success(()))
    await settle()

    // Unliked elsewhere meanwhile: the server's answer wins, also over a
    // list loaded before.
    store.adoptServerState(false, id: "s1")
    XCTAssertFalse(store.isStarred("s1", listed: true))

    // A waiting edit still wins over the server.
    reachable = false
    store.set(true, id: "s1")
    store.adoptServerState(false, id: "s1")
    XCTAssertTrue(store.isStarred("s1", listed: false))
  }

  func testAFreshStarredListIsAdoptedUnlessAnEditCameInBetween() {
    let store = makeStore()
    store.adoptServerState(false, id: "s1")
    store.adoptServerStars(["s1"], since: store.listRevision)
    XCTAssertTrue(store.isStarred("s1", listed: false))

    let since = store.listRevision
    reachable = false
    store.set(false, id: "s2")
    store.adoptServerStars(["s2"], since: since)
    XCTAssertFalse(store.isStarred("s2", listed: false))
  }

  func testAStarredListIsOverlaidWithTheStoresStars() {
    reachable = false
    let store = makeStore()
    store.set(true, id: "s1")
    store.set(false, id: "s2")
    XCTAssertEqual(store.starred(listed: ["s2", "s3"]), ["s1", "s3"])
  }

  func testASongMissingFromAFreshListIsUnstarred() {
    let store = makeStore()
    store.adoptServerStars(["s1", "s2"], since: store.listRevision)
    store.adoptServerStars(["s2"], since: store.listRevision)
    XCTAssertFalse(store.isStarred("s1", listed: true))
    XCTAssertTrue(store.isStarred("s2", listed: false))
    // An item no song list had keeps its state.
    XCTAssertTrue(store.isStarred("al1", listed: true))
  }

  /// An album liked here and unliked elsewhere shows unliked once a fresh
  /// full list says so; an artist liked elsewhere shows liked.
  func testAFreshAlbumOrArtistListReplacesEarlierConfirmations() async {
    let store = makeStore()
    store.set(true, id: "al1")
    store.set(false, id: "ar1")
    answers[0](.success(()))
    answers[1](.success(()))
    await settle()

    store.adoptServerList([("al1", false), ("al2", true)], since: store.listRevision)
    store.adoptServerList([("ar1", true)], since: store.listRevision)
    XCTAssertFalse(store.isStarred("al1", listed: true))
    XCTAssertTrue(store.isStarred("ar1", listed: false))
    // An item edited nowhere keeps the state it is listed with.
    XCTAssertFalse(store.isStarred("al2", listed: false))
  }

  /// A waiting like stays on top of a fresh list, and a list asked for
  /// before an edit is dropped.
  func testAPendingAlbumOrArtistLikeWinsOverAFreshList() async {
    reachable = false
    let store = makeStore()
    store.set(true, id: "al1")
    store.set(false, id: "ar1")
    store.adoptServerList([("al1", false), ("ar1", true)], since: store.listRevision)
    XCTAssertTrue(store.isStarred("al1", listed: false))
    XCTAssertFalse(store.isStarred("ar1", listed: true))
    XCTAssertEqual(store.starred(listed: ["ar1"]), ["al1"])

    reachable = true
    let taken = makeStore()
    let before = taken.listRevision
    taken.set(true, id: "ar1")
    answers[0](.success(()))
    await settle()
    taken.adoptServerList([("ar1", false)], since: before)
    XCTAssertTrue(taken.isStarred("ar1", listed: false))
  }
}
