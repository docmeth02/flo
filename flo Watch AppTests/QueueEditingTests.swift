import CoreData
import XCTest

@testable import flo_Watch_App

final class QueueEditingTests: XCTestCase {
  private var service: PlaybackService!

  override func setUpWithError() throws {
    let container = CoreDataManager.inMemoryContainer()
    service = PlaybackService(context: container.viewContext)
  }

  private func entries(_ ids: String...) -> [QueueEntity] {
    ids.map {
      service.makeEntry(
        song: Song(
          id: $0, title: "Song \($0)", albumId: "album", albumName: "Album", artist: "Artist",
          trackNumber: 1, discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3",
          duration: 200, mediaFileId: ""),
        context: "Album", isFromPlaylist: false)
    }
  }

  private func assertStored(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
    let stored = service.getQueue()
    XCTAssertEqual(stored.map(\.id), ids, file: file, line: line)
    XCTAssertEqual(stored.map(\.position), Array(0..<Int32(ids.count)), file: file, line: line)
  }

  func testEditsKeepTheStoredOrder() {
    var order = entries("a", "b", "c")
    XCTAssertTrue(service.store(order: order))
    assertStored(["a", "b", "c"])

    // Play Next after "a", then Add to Queue.
    order.insert(contentsOf: entries("x", "y"), at: 1)
    XCTAssertTrue(service.store(order: order))
    assertStored(["a", "x", "y", "b", "c"])
    order.append(contentsOf: entries("z"))
    XCTAssertTrue(service.store(order: order))
    assertStored(["a", "x", "y", "b", "c", "z"])

    // A removed row is deleted, not just left out.
    let removed = order.remove(at: 3)
    XCTAssertTrue(service.store(order: order))
    assertStored(["a", "x", "y", "c", "z"])
    XCTAssertTrue(removed.isDeleted || removed.managedObjectContext == nil)

    // Moved next: the same rows, renumbered.
    order.insert(order.remove(at: 4), at: 1)
    XCTAssertTrue(service.store(order: order))
    assertStored(["a", "z", "x", "y", "c"])
  }

  /// Undo rebuilds a removed row from its values; it must be the same song.
  func testUndoSnapshotRebuildsTheRow() {
    let original = entries("b")[0]
    original.isFromPlaylist = true
    let song = Song(from: original)
    let rebuilt = service.makeEntry(
      song: song, context: original.contextName ?? "", isFromPlaylist: original.isFromPlaylist)

    for key in original.entity.attributesByName.keys where key != "position" {
      XCTAssertEqual(
        original.value(forKey: key) as? NSObject, rebuilt.value(forKey: key) as? NSObject, key)
    }
  }
}
