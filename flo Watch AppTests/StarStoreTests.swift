import XCTest

@testable import flo_Watch_App

@MainActor
final class StarStoreTests: XCTestCase {
  private var reachable = true
  private var answers: [(Result<Void, Error>) -> Void] = []

  private func makeStore() -> StarStore {
    let name = "StarStoreTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return StarStore(
      defaults: UserDefaults(suiteName: name)!, canSend: { [unowned self] in self.reachable },
      send: { [unowned self] _, _, completion in self.answers.append(completion) })
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
    store.adoptServerStars(["s1"], since: store.editCount)
    XCTAssertTrue(store.isStarred("s1", listed: false))

    let since = store.editCount
    reachable = false
    store.set(false, id: "s2")
    store.adoptServerStars(["s2"], since: since)
    XCTAssertFalse(store.isStarred("s2", listed: false))
  }
}
