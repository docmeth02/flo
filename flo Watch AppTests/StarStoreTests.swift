import XCTest

@testable import flo_Watch_App

@MainActor
final class StarStoreTests: XCTestCase {
  private var reachable = true
  private var answers: [(Result<Void, Error>) -> Void] = []

  private func makeStore(defaults: UserDefaults? = nil) -> StarStore {
    StarStore(
      defaults: defaults ?? makeDefaults(), canSend: { [unowned self] in self.reachable },
      send: { [unowned self] _, _, completion in self.answers.append(completion) })
  }

  private func makeDefaults() -> UserDefaults {
    let name = "StarStoreTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
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
    for _ in 0..<5 { await Task.yield() }
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
    for _ in 0..<5 { await Task.yield() }

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
    for _ in 0..<5 { await Task.yield() }
    XCTAssertFalse(store.isStarred("s1", listed: true))
  }

  func testPendingEditWinsOverAConfirmedStar() async {
    let store = makeStore()
    store.set(true, id: "s1")
    answers[0](.success(()))
    for _ in 0..<5 { await Task.yield() }

    reachable = false
    store.set(false, id: "s1")
    XCTAssertFalse(store.isStarred("s1", listed: true))
  }

  func testFreshServerStateReplacesAnEarlierConfirmation() async {
    let store = makeStore()
    store.set(true, id: "s1")
    answers[0](.success(()))
    for _ in 0..<5 { await Task.yield() }

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
}
