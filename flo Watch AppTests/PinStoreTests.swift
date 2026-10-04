import XCTest

@testable import flo_Watch_App

@MainActor
final class PinStoreTests: XCTestCase {
  /// A fresh defaults suite, removed when the test ends.
  private func makeDefaults() -> UserDefaults {
    let name = "PinStoreTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  func testToggleAddsAndRemovesAPin() {
    let store = PinStore(defaults: makeDefaults(), account: { "server|alice" })
    store.toggle("al1", .album)
    XCTAssertTrue(store.isPinned("al1", .album))
    XCTAssertFalse(store.isPinned("al1", .artist))
    store.toggle("al1", .album)
    XCTAssertEqual(store.pinned(.album), [])
  }

  func testPinsAreKeptPerAccount() {
    let defaults = makeDefaults()
    var account = "server|alice"
    let store = PinStore(defaults: defaults, account: { account })
    store.toggle("ar1", .artist)
    account = "server|bob"
    XCTAssertEqual(store.pinned(.artist), [])
    store.toggle("ar2", .artist)
    account = "server|alice"
    XCTAssertEqual(store.pinned(.artist), ["ar1"])
  }

  func testPinsSurviveANewStore() {
    let defaults = makeDefaults()
    PinStore(defaults: defaults, account: { "server|alice" }).toggle("al1", .album)
    XCTAssertEqual(PinStore(defaults: defaults, account: { "server|alice" }).pinned(.album), ["al1"])
  }

  func testNothingIsPinnedWithoutAnAccount() {
    let defaults = makeDefaults()
    PinStore(defaults: defaults, account: { "server|alice" }).toggle("al1", .album)
    let store = PinStore(defaults: defaults, account: { nil })
    XCTAssertEqual(store.pinned(.album), [])
    store.toggle("al2", .album)
    XCTAssertFalse(store.isPinned("al2", .album))
    XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("pins.") }.count, 1)
  }
}
