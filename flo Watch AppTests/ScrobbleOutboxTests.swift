import Combine
import CoreData
import XCTest

@testable import flo_Watch_App

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
  private var probes = 0
  private var sends: [(songId: String, storedRows: Int, complete: (Result<Void, Error>) -> Void)] =
    []

  override func setUpWithError() throws {
    // The app's model: a second copy of it makes the entity classes ambiguous.
    let container = NSPersistentContainer(
      name: "flo", managedObjectModel: CoreDataManager.shared.persistentContainer.managedObjectModel)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in XCTAssertNil(error) }
    store = Store()
    store.persistentContainer = container

    triggers = PassthroughSubject()
    outbox = ScrobbleQueueManager(
      store: store,
      send: { [unowned self] songId, _, completion in
        sends.append((songId, store.countRecords(entity: ScrobbleEntity.self), completion))
      },
      canReachServer: { [unowned self] in reachable },
      probeServer: { [unowned self] in probes += 1 },
      flushTriggers: triggers.eraseToAnyPublisher())
  }

  override func tearDown() {
    // A retry timer still pending must find no outbox.
    outbox = nil
    store = nil
  }

  private func payload(_ songId: String) -> ScrobblePayload {
    let entity = NSEntityDescription.entity(forEntityName: "QueueEntity", in: store.viewContext)!
    let row = QueueEntity(entity: entity, insertInto: nil)
    row.id = songId
    return ScrobblePayload(nowPlaying: row, accountGeneration: outbox.accountGeneration)!
  }

  /// Lets the outbox handle a send result, which it takes on the main queue.
  private func answer(_ index: Int, _ result: Result<Void, Error>) {
    sends[index].complete(result)
    let handled = expectation(description: "main queue")
    DispatchQueue.main.async { handled.fulfill() }
    wait(for: [handled], timeout: 1)
  }

  private var storedRows: [ScrobbleEntity] {
    store.getRecordsByEntity(entity: ScrobbleEntity.self)
  }

  func testEnqueueStoresBeforeSending() {
    outbox.enqueue(payload("a"))
    XCTAssertEqual(sends.map(\.songId), ["a"])
    XCTAssertEqual(sends[0].storedRows, 1)
  }

  func testUnreachableServerKeepsTheEntryUnsent() {
    reachable = false
    outbox.enqueue(payload("a"))
    XCTAssertTrue(sends.isEmpty)
    XCTAssertEqual(storedRows.map(\.songId), ["a"])

    // A trigger while still unreachable asks for a probe instead of sending.
    triggers.send()
    XCTAssertTrue(sends.isEmpty)
    XCTAssertEqual(probes, 1)

    reachable = true
    triggers.send()
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

  func testDeliveredEntryIsDeleted() {
    outbox.enqueue(payload("a"))
    answer(0, .success(()))
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testPermanentFailureDropsTheEntry() {
    outbox.enqueue(payload("a"))
    answer(0, .failure(SubsonicError(code: 70, message: "not found")))
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }

  func testTransientFailureKeepsTheEntryAndBacksOff() {
    let initialDelay = outbox.retryDelay
    outbox.enqueue(payload("a"))
    answer(0, .failure(URLError(.timedOut)))
    XCTAssertEqual(outbox.pendingCount, 1)
    XCTAssertEqual(storedRows.map(\.status), ["failed"])
    XCTAssertEqual(outbox.retryDelay, initialDelay * 2)

    // The next chance sends it again; once delivered the delay starts over.
    triggers.send()
    XCTAssertEqual(sends.map(\.songId), ["a", "a"])
    answer(1, .success(()))
    XCTAssertTrue(storedRows.isEmpty)
    XCTAssertEqual(outbox.retryDelay, initialDelay)
  }

  func testAcceptedEntryWhoseDeleteFailedIsNotSentAgain() {
    outbox.enqueue(payload("a"))
    store.failSaves = true
    answer(0, .success(()))
    // The failed save rolled the delete back.
    XCTAssertEqual(outbox.pendingCount, 1)

    store.failSaves = false
    triggers.send()
    XCTAssertEqual(sends.count, 1)
    XCTAssertEqual(outbox.pendingCount, 0)
    XCTAssertTrue(storedRows.isEmpty)
  }
}
