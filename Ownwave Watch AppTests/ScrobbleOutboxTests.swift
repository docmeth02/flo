import Combine
import CoreData
import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

@MainActor
final class ScrobbleOutboxTests: XCTestCase {
  /// A store on a memory container whose saves can be made to fail.
  private final class Store: CoreDataManager {
    var failSaves = false

    @discardableResult
    override func saveRecord() -> Bool {
      guard failSaves else { return super.saveRecord() }
      viewContext.rollback()
      return false
    }
  }

  private var store: Store!
  private var outbox: ScrobbleQueueManager!
  private var triggers: PassthroughSubject<Void, Never>!
  private var reachable = true
  private var account: String? = "server|a"
  private var receiptsURL: URL!
  private var probes = 0
  private var sends: [(songId: String, storedRows: Int, complete: (Result<Void, Error>) -> Void)] =
    []

  override func setUpWithError() throws {
    let container = CoreDataManager.inMemoryContainer()
    store = Store()
    store.persistentContainer = container

    receiptsURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("receipts.json")
    triggers = PassthroughSubject()
    makeOutbox()
  }

  /// A new outbox over the same store and receipts file, as after a relaunch.
  private func makeOutbox() {
    outbox = ScrobbleQueueManager(
      store: store,
      receipts: ScrobbleReceipts(fileURL: receiptsURL),
      accountKey: { [unowned self] in account },
      send: { @MainActor [unowned self] songId, _ in
        let storedRows = self.store.countRecords(entity: ScrobbleEntity.self)
        try await answeredByTest { self.sends.append((songId, storedRows, $0)) }
      },
      canReachServer: { [unowned self] in reachable },
      probeServer: { [unowned self] in probes += 1 },
      flushTriggers: triggers.eraseToAnyPublisher())
  }

  override func tearDown() {
    // A retry timer still pending must find no outbox.
    outbox = nil
    store = nil
    try? FileManager.default.removeItem(at: receiptsURL.deletingLastPathComponent())
  }

  private func payload(_ songId: String) -> ScrobblePayload {
    let entity = NSEntityDescription.entity(forEntityName: "QueueEntity", in: store.viewContext)!
    let row = QueueEntity(entity: entity, insertInto: nil)
    row.id = songId
    return ScrobblePayload(nowPlaying: row, accountGeneration: outbox.accountGeneration)!
  }

  /// Lets the outbox handle a send result, which it takes on the main actor.
  private func answer(_ index: Int, _ result: Result<Void, Error>) async {
    sends[index].complete(result)
    await settle()
  }

  private var storedRows: [ScrobbleEntity] {
    store.getRecordsByEntity(entity: ScrobbleEntity.self)
  }

  func testEnqueueStoresBeforeSending() async {
    outbox.enqueue(payload("a"))
    await settle()
    XCTAssertEqual(sends.map(\.songId), ["a"])
    XCTAssertEqual(sends[0].storedRows, 1)
  }

  func testUnreachableServerKeepsTheEntryUnsent() async {
    reachable = false
    outbox.enqueue(payload("a"))
    await settle()
    XCTAssertTrue(sends.isEmpty)
    XCTAssertEqual(storedRows.map(\.songId), ["a"])

    // A trigger while still unreachable asks for a probe instead of sending.
    triggers.send()
    await settle()
    XCTAssertTrue(sends.isEmpty)
    XCTAssertEqual(probes, 1)

    reachable = true
    triggers.send()
    await settle()
    XCTAssertEqual(sends.map(\.songId), ["a"])
  }

  func testTheSameSongWithinTenSecondsIsQueuedOnce() {
    reachable = false
    outbox.enqueue(payload("a"))
    outbox.enqueue(payload("a"))
    outbox.enqueue(payload("b"))
    XCTAssertEqual(outbox.pendingCount, 2)
    XCTAssertEqual(Set(storedRows.compactMap(\.songId)), ["a", "b"])
  }

  func testDeliveredEntryIsDeleted() async {
    outbox.enqueue(payload("a"))
    await settle()
    await answer(0, .success(()))
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testPermanentFailureDropsTheEntry() async {
    outbox.enqueue(payload("a"))
    await settle()
    await answer(0, .failure(SubsonicError(code: 70, message: "not found")))
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testTransientFailureKeepsTheEntryAndBacksOff() async {
    let initialDelay = outbox.retryDelay
    outbox.enqueue(payload("a"))
    await settle()
    await answer(0, .failure(URLError(.timedOut)))
    XCTAssertEqual(outbox.pendingCount, 1)
    XCTAssertEqual(storedRows.count, 1)
    XCTAssertEqual(outbox.retryDelay, initialDelay * 2)

    // The next chance sends it again; once delivered the delay starts over.
    triggers.send()
    await settle()
    XCTAssertEqual(sends.map(\.songId), ["a", "a"])
    await answer(1, .success(()))
    XCTAssertTrue(storedRows.isEmpty)
    XCTAssertEqual(outbox.retryDelay, initialDelay)
  }

  func testAcceptedEntryWhoseDeleteFailedIsNotSentAgain() async {
    outbox.enqueue(payload("a"))
    await settle()
    store.failSaves = true
    await answer(0, .success(()))
    // The failed save rolled the delete back.
    XCTAssertEqual(outbox.pendingCount, 1)

    store.failSaves = false
    triggers.send()
    await settle()
    XCTAssertEqual(sends.count, 1)
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testAcceptedEntryIsNotResentAfterARelaunch() async {
    outbox.enqueue(payload("a"))
    await settle()
    store.failSaves = true
    await answer(0, .success(()))

    // Relaunched while deletes still fail: the receipt keeps it from the server.
    makeOutbox()
    triggers.send()
    await settle()
    XCTAssertEqual(sends.count, 1)
    XCTAssertEqual(outbox.pendingCount, 1)

    // Once the delete saves, the receipt goes too.
    store.failSaves = false
    makeOutbox()
    triggers.send()
    await settle()
    XCTAssertEqual(sends.count, 1)
    XCTAssertTrue(storedRows.isEmpty)
    XCTAssertEqual(try Data(contentsOf: receiptsURL), Data("[]".utf8))
  }

  /// A delivered row is never sent again, also not under the next account.
  func testADeliveredRowIsNotResentUnderAnotherAccount() async {
    outbox.enqueue(payload("a"))
    await settle()
    store.failSaves = true
    await answer(0, .success(()))

    store.failSaves = false
    account = "server|b"
    makeOutbox()
    triggers.send()
    await settle()
    XCTAssertEqual(sends.map(\.songId), ["a"])
  }

  func testReceiptsWhoseRowIsGoneAreDropped() {
    let stale = ScrobbleReceipts.Receipt(row: "x-coredata://gone/ScrobbleEntity/p1")
    ScrobbleReceipts(fileURL: receiptsURL).insert(stale)
    XCTAssertTrue(ScrobbleReceipts(fileURL: receiptsURL).contains(stale))

    makeOutbox()
    XCTAssertFalse(ScrobbleReceipts(fileURL: receiptsURL).contains(stale))
  }

  func testUnsavedReceiptStillProtectsThisProcess() async throws {
    // A regular file where the receipts directory should be.
    let blocker = receiptsURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: blocker)
    makeOutbox()

    outbox.enqueue(payload("a"))
    await settle()
    store.failSaves = true
    await answer(0, .success(()))
    XCTAssertEqual(outbox.pendingCount, 1)

    store.failSaves = false
    triggers.send()
    await settle()
    XCTAssertEqual(sends.count, 1)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testNothingIsSentWithoutALogin() async {
    account = nil
    outbox.enqueue(payload("a"))
    await settle()
    XCTAssertTrue(sends.isEmpty)
    XCTAssertEqual(outbox.pendingCount, 1)

    account = "server|a"
    triggers.send()
    await settle()
    XCTAssertEqual(sends.map(\.songId), ["a"])
  }

  func testPendingListensAreTheCurrentAccountsQueuedPlays() {
    reachable = false
    let first = payload("a")
    outbox.enqueue(first)
    outbox.enqueue(payload("b"))
    XCTAssertEqual(outbox.pendingListens().map(\.songId), ["a", "b"])
    XCTAssertEqual(outbox.pendingListens().first?.at, first.listenTime)

    // Logged out, or the login unreadable: no account owns them.
    account = nil
    XCTAssertTrue(outbox.pendingListens().isEmpty)

    // A logout drops the rows, and a play of the previous account stays out.
    account = "server|b"
    outbox.clearAll()
    outbox.enqueue(first)
    XCTAssertTrue(outbox.pendingListens().isEmpty)
  }
}
