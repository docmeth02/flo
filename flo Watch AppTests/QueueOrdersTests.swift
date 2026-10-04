import XCTest

@testable import flo_Watch_App

final class QueueOrdersTests: XCTestCase {
  private final class Row {
    let id: String
    init(_ id: String) { self.id = id }
  }

  private var rows: [String: Row] = [:]

  private func row(_ id: String) -> Row {
    if let row = rows[id] { return row }
    let row = Row(id)
    rows[id] = row
    return row
  }

  private func list(_ ids: String) -> [Row] { ids.map { row(String($0)) } }

  /// Stored order "abcde", played shuffled as "caebd", "a" playing.
  private func shuffled() -> QueueOrders<Row> {
    QueueOrders(played: list("caebd"), stored: list("abcde"), currentIndex: 1, isShuffling: true)
  }

  /// Played and stored as "abcde", "b" playing. Unshuffled the player keeps
  /// no separate stored order.
  private func unshuffled() -> QueueOrders<Row> {
    QueueOrders(played: list("abcde"), stored: [], currentIndex: 1, isShuffling: false)
  }

  private func ids(_ order: [Row]) -> String { order.map(\.id).joined() }

  /// Both orders hold the same rows once each, and the current row is where
  /// `currentIndex` says.
  private func assertConsistent(
    _ orders: QueueOrders<Row>, current: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(orders.played[orders.currentIndex] === row(current), file: file, line: line)
    let played = orders.played.map(ObjectIdentifier.init)
    XCTAssertEqual(Set(played).count, played.count, file: file, line: line)
    if orders.isShuffling {
      XCTAssertEqual(
        played.sorted(), orders.stored.map(ObjectIdentifier.init).sorted(), file: file, line: line)
    } else {
      XCTAssertTrue(orders.stored.isEmpty, file: file, line: line)
    }
    XCTAssertEqual(
      ids(orders.toStore), ids(orders.isShuffling ? orders.stored : orders.played), file: file,
      line: line)
  }

  func testPlayNext() {
    var orders = shuffled()
    orders.insertAfterCurrent(list("xy"))
    XCTAssertEqual(ids(orders.played), "caxyebd")
    XCTAssertEqual(ids(orders.stored), "axybcde")
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.insertAfterCurrent(list("xy"))
    XCTAssertEqual(ids(orders.played), "abxycde")
    assertConsistent(orders, current: "b")
  }

  func testAddToQueue() {
    var orders = shuffled()
    orders.append(list("xy"))
    XCTAssertEqual(ids(orders.played), "caebdxy")
    XCTAssertEqual(ids(orders.stored), "abcdexy")
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.append(list("xy"))
    XCTAssertEqual(ids(orders.played), "abcdexy")
    assertConsistent(orders, current: "b")
  }

  func testRemove() {
    var orders = shuffled()
    orders.remove(row("c"))
    XCTAssertEqual(ids(orders.played), "aebd")
    XCTAssertEqual(ids(orders.stored), "abde")
    XCTAssertEqual(orders.currentIndex, 0)
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.remove(row("d"))
    XCTAssertEqual(ids(orders.played), "abce")
    assertConsistent(orders, current: "b")
  }

  func testUndoPutsTheRowBack() {
    var orders = shuffled()
    orders.remove(row("e"))
    orders.reinsert(row("e"), at: 2, storedIndex: 4)
    XCTAssertEqual(ids(orders.played), "caebd")
    XCTAssertEqual(ids(orders.stored), "abcde")
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.remove(row("d"))
    orders.reinsert(row("d"), at: 3, storedIndex: 3)
    XCTAssertEqual(ids(orders.played), "abcde")
    assertConsistent(orders, current: "b")
  }

  /// A row removed before the current one comes back after it, and one whose
  /// place is gone goes to the end.
  func testUndoNeverGoesBeforeTheCurrentRow() {
    var orders = shuffled()
    orders.remove(row("c"))
    orders.reinsert(row("c"), at: 0, storedIndex: 2)
    XCTAssertEqual(ids(orders.played), "acebd")
    XCTAssertEqual(ids(orders.stored), "abcde")
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.remove(row("a"))
    orders.remove(row("e"))
    orders.reinsert(row("a"), at: 0, storedIndex: 0)
    orders.reinsert(row("e"), at: 9, storedIndex: 9)
    XCTAssertEqual(ids(orders.played), "bacde")
    assertConsistent(orders, current: "b")
  }

  func testMoveNext() {
    var orders = shuffled()
    orders.moveNext(row("d"))
    XCTAssertEqual(ids(orders.played), "cadeb")
    XCTAssertEqual(ids(orders.stored), "adbce")
    assertConsistent(orders, current: "a")

    // A row before the current one moves behind it.
    orders.moveNext(row("c"))
    XCTAssertEqual(ids(orders.played), "acdeb")
    XCTAssertEqual(orders.currentIndex, 0)
    assertConsistent(orders, current: "a")

    orders = unshuffled()
    orders.moveNext(row("e"))
    XCTAssertEqual(ids(orders.played), "abecd")
    assertConsistent(orders, current: "b")
  }
}
