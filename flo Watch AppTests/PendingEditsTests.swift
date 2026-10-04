import XCTest

@testable import flo_Watch_App

@MainActor
final class PendingEditsTests: XCTestCase {
  /// Edits handed to the server, answered by the test.
  private final class FakeServer {
    var reachable = true
    var sent: [(id: String, value: Int, answer: (Result<Void, Error>) -> Void)] = []
  }

  private let key = "pending"

  /// A fresh defaults suite, removed when the test ends.
  private func makeDefaults() -> UserDefaults {
    let name = "PendingEditsTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  private func makeEdits(
    _ server: FakeServer, defaults: UserDefaults
  ) -> (PendingEdits<Int>, settled: () -> [(String, Int, Bool)]) {
    let edits = PendingEdits<Int>(
      name: "test", key: key, defaults: defaults, canSend: { server.reachable },
      send: { id, value, completion in server.sent.append((id, value, completion)) })
    var settled: [(String, Int, Bool)] = []
    edits.onSettle = { settled.append(($0, $1, $2)) }
    return (edits, { settled })
  }

  /// Lets the answer's hop to the main actor run.
  private func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  func testPendingEditSurvivesANewInstance() {
    let defaults = makeDefaults()
    let server = FakeServer()
    server.reachable = false
    makeEdits(server, defaults: defaults).0.set(4, id: "s1")
    XCTAssertTrue(server.sent.isEmpty)

    let (edits, _) = makeEdits(server, defaults: defaults)
    XCTAssertEqual(edits["s1"], 4)
    server.reachable = true
    edits.flush()
    XCTAssertEqual(server.sent.map(\.id), ["s1"])
  }

  func testSuccessSettlesAsAccepted() async {
    let defaults = makeDefaults()
    let server = FakeServer()
    let (edits, settled) = makeEdits(server, defaults: defaults)
    edits.set(5, id: "s1")
    server.sent[0].answer(.success(()))
    await settle()

    XCTAssertNil(edits["s1"])
    XCTAssertTrue(edits.isIdle)
    XCTAssertEqual(settled().map { "\($0.0)=\($0.1) \($0.2)" }, ["s1=5 true"])
    XCTAssertNil(makeEdits(server, defaults: defaults).0["s1"])
  }

  func testPermanentFailureDropsTheEdit() async {
    let server = FakeServer()
    let (edits, settled) = makeEdits(server, defaults: makeDefaults())
    edits.set(3, id: "gone")
    server.sent[0].answer(.failure(SubsonicError(code: 70, message: "not found")))
    await settle()

    XCTAssertNil(edits["gone"])
    XCTAssertEqual(settled().map { "\($0.0)=\($0.1) \($0.2)" }, ["gone=3 false"])
  }

  func testTransientFailureKeepsTheEditForTheNextFlush() async {
    let server = FakeServer()
    let (edits, settled) = makeEdits(server, defaults: makeDefaults())
    edits.set(2, id: "s1")
    server.sent[0].answer(.failure(URLError(.notConnectedToInternet)))
    await settle()

    XCTAssertEqual(edits["s1"], 2)
    XCTAssertTrue(settled().isEmpty)
    edits.flush()
    XCTAssertEqual(server.sent.count, 2)
  }

  func testEditMadeWhileInFlightIsSentAfterwards() async {
    let server = FakeServer()
    let (edits, settled) = makeEdits(server, defaults: makeDefaults())
    edits.set(1, id: "s1")
    edits.set(4, id: "s1")
    // The first is still under way; the second waits for it.
    XCTAssertEqual(server.sent.count, 1)

    server.sent[0].answer(.success(()))
    await settle()
    XCTAssertEqual(edits["s1"], 4)
    XCTAssertEqual(server.sent.map(\.value), [1, 4])
    XCTAssertFalse(edits.isIdle)

    server.sent[1].answer(.success(()))
    await settle()
    XCTAssertTrue(edits.isIdle)
    XCTAssertEqual(settled().map(\.1), [1, 4])
  }

  func testAnswerAfterLogoutIsDropped() async {
    let server = FakeServer()
    let (edits, settled) = makeEdits(server, defaults: makeDefaults())
    edits.set(5, id: "s1")
    edits.forgetAccount()
    server.sent[0].answer(.success(()))
    await settle()

    XCTAssertTrue(edits.isIdle)
    XCTAssertTrue(settled().isEmpty)
  }
}
