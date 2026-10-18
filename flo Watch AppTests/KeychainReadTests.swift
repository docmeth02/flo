import XCTest

#if canImport(flo_Watch_App)
  @testable import flo_Watch_App
#endif

final class KeychainReadTests: XCTestCase {
  private struct Locked: Error {}

  private func read(_ item: String?) -> KeychainRead<Int> {
    KeychainRead({ item }) { Int($0) }
  }

  func testAnItemThatParsesIsFound() {
    guard case .found(7) = read("7") else { return XCTFail() }
  }

  func testNoItemIsMissing() {
    guard case .missing = read(nil) else { return XCTFail() }
  }

  func testAnItemThatDoesNotParseIsMissing() {
    guard case .missing = read("seven") else { return XCTFail() }
  }

  func testAReadErrorIsUnreadableNotMissing() {
    let result = KeychainRead<Int>({ throw Locked() }) { Int($0) }
    guard case .unreadable(let error) = result, error is Locked else { return XCTFail() }
  }
}
