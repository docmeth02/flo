import CoreData
import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

/// The engine's small pure rules: history folding, skip weights, account
/// keys, error and status parsing, and the diagnostics lines.
@MainActor
final class EngineRulesTests: XCTestCase {
  /// Two plays a half-life apart weigh 1.5 at the later one, in either order.
  func testHistoryFoldDecaysOlderPlays() throws {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let later = start.addingTimeInterval(ListeningHistoryStore.halfLife)

    for times in [[start, later], [later, start]] {
      let context = CoreDataManager.inMemoryContainer().viewContext
      ListeningHistoryStore.apply(
        times.map { ListeningHistoryStore.Fold(kind: .song, key: "s1", time: $0, weight: 1) },
        key: "acc", generation: 1, in: context)
      let rows = try context.fetch(NSFetchRequest<AffinityEntity>(entityName: "AffinityEntity"))
      let row = try XCTUnwrap(rows.first)
      XCTAssertEqual(rows.count, 1)
      XCTAssertEqual(row.weight, 1.5, accuracy: 1e-9)
      XCTAssertEqual(row.referenceTime, later)
      XCTAssertEqual(row.lastPlayAt, later)
      XCTAssertEqual(row.plays, 2)
    }
  }

  /// An early skip of a song the app picked weighs most, one the user picked least.
  func testSkipWeights() {
    let early = PlaybackJournal.earlySkipSeconds
    XCTAssertEqual(PlaybackJournal.skipWeight(origin: "smartShuffle", listened: early), 1.5)
    XCTAssertEqual(PlaybackJournal.skipWeight(origin: "keepPlaying", listened: early + 1), 1)
    XCTAssertEqual(PlaybackJournal.skipWeight(origin: "album", listened: 0), 0.75)
    XCTAssertEqual(PlaybackJournal.skipWeight(origin: nil, listened: 0), 0.75)
  }

  func testAccountKeyIgnoresCaseAndTrailingSlashes() {
    XCTAssertEqual(
      AuthService.accountKey(serverURL: "https://Music.Example.com:4533/navidrome/", userId: "u1"),
      "music.example.com:4533/navidrome|u1")
    XCTAssertEqual(
      AuthService.accountKey(serverURL: "https://music.lan", userId: "u1"), "music.lan|u1")
    XCTAssertNil(AuthService.accountKey(serverURL: "https://music.lan", userId: nil))
    XCTAssertNil(AuthService.accountKey(serverURL: "", userId: "u1"))
  }

  func testServerAccountSplitsAuthorityAndPath() {
    let url = "https://anna:secret@Music.lan:4533/navidrome?x=1"
    XCTAssertEqual(ServerAccount.authority(of: url), "Music.lan:4533")
    XCTAssertEqual(ServerAccount.path(of: url), "/navidrome")
    XCTAssertEqual(ServerAccount.authority(of: "https://music.lan"), "music.lan")
    XCTAssertEqual(ServerAccount.path(of: "https://music.lan/"), "")
    // An address that does not parse stays whole, without a path.
    XCTAssertEqual(ServerAccount.authority(of: "music lan"), "music lan")
    XCTAssertEqual(ServerAccount.path(of: "music lan"), "")
  }

  func testStorageBarWidths() {
    XCTAssertEqual(StorageUsage(cache: 100, downloads: 300, free: 600).used, 400)
    // Shares of the parts shown, here downloads and free without the cache.
    XCTAssertEqual(
      StorageUsage.barWidths([300, 700], in: 102, gap: 2, minimum: 5), [30, 70])
    // A small part keeps the minimum; the widest gives up that room.
    let widths = StorageUsage.barWidths([1, 999], in: 102, gap: 2, minimum: 5)
    XCTAssertEqual(widths[0], 5)
    XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 1e-9)
    // Nothing known yet, or no room: no widths below zero.
    XCTAssertEqual(StorageUsage.barWidths([0, 0], in: 100, gap: 2, minimum: 5), [0, 0])
    XCTAssertEqual(StorageUsage.barWidths([1, 2], in: 0, gap: 2, minimum: 5), [0, 0])
    XCTAssertEqual(StorageUsage.barWidths([], in: 100, gap: 2, minimum: 5), [])
    XCTAssertTrue(
      StorageUsage.barWidths([1, 1, 1], in: 8, gap: 2, minimum: 5).allSatisfy { $0 >= 0 })
  }

  /// The platform's free space: the watch's file system figure, the phone's
  /// important-usage capacity; known and never negative on both.
  func testFreeBytes() {
    XCTAssertGreaterThan(AppPlatform.freeBytes(), 0)
  }

  /// Only a rejected login reads as a wrong password.
  func testLoginErrors() {
    let rejected = AuthError.invalidCredentials(message: "Invalid Username or Password")
    XCTAssertTrue(rejected.isCredentialError)
    XCTAssertEqual(rejected.loginMessage, "Wrong username or password.")
    let offline = AuthError.server(message: "The Internet connection appears to be offline.")
    XCTAssertFalse(offline.isCredentialError)
    XCTAssertEqual(offline.loginMessage, "The Internet connection appears to be offline.")
    XCTAssertFalse(AuthError.sessionExpired.isCredentialError)
    XCTAssertFalse(AuthError.unknown.isCredentialError)
  }

  func testServerURLLosesWhitespaceAndTrailingSlashes() {
    XCTAssertEqual(
      UserDefaultsManager.baseURL(" https://music.lan/nd// \n"), "https://music.lan/nd")
    XCTAssertEqual(UserDefaultsManager.baseURL(""), "")
  }

  /// A dropped connection counts, also wrapped by AVFoundation; a server
  /// answer does not.
  func testConnectionErrors() {
    XCTAssertTrue(ConnectivityMonitor.isConnectionError(URLError(.timedOut)))
    XCTAssertTrue(ConnectivityMonitor.isConnectionError(URLError(.networkConnectionLost)))
    let wrapped = NSError(
      domain: "AVFoundationErrorDomain", code: -11800,
      userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet) as NSError])
    XCTAssertTrue(ConnectivityMonitor.isConnectionError(wrapped))
    XCTAssertFalse(ConnectivityMonitor.isConnectionError(URLError(.badServerResponse)))
    XCTAssertFalse(ConnectivityMonitor.isConnectionError(nil))
  }

  /// An async call's answer or error, kept for code that handles both.
  func testResultOfAnAsyncCall() async throws {
    func answer(failing: Bool) async throws -> Int {
      if failing { throw URLError(.timedOut) }
      return 1
    }
    let answered = await Result { try await answer(failing: false) }
    XCTAssertEqual(try answered.get(), 1)
    guard case .failure(let error) = await Result(catching: { try await answer(failing: true) })
    else { return XCTFail("no failure") }
    XCTAssertEqual((error as? URLError)?.code, .timedOut)
  }

  func testExplicitStatusReadsEveryServerSpelling() {
    for raw in ["e", "Explicit", " 1 ", "4"] {
      XCTAssertEqual(ExplicitStatus(from: raw), .explicit, raw)
    }
    for raw in ["c", "CLEAN", "2"] {
      XCTAssertEqual(ExplicitStatus(from: raw), .clean, raw)
    }
    XCTAssertEqual(ExplicitStatus(from: nil), .unknown)
    XCTAssertEqual(ExplicitStatus(from: "0"), .unknown)
  }

  func testStationShowsItsHost() {
    XCTAssertEqual(
      Radio.displayHost(from: "https://radio.example.com:8000/live"), "radio.example.com")
    XCTAssertEqual(Radio.displayHost(from: "stream"), "stream")
  }

  /// Subsonic calls are named by method, never with their query, which holds
  /// the credentials.
  func testRequestLogNamesRequestsWithoutQueries() {
    func describe(_ url: String, method: String = "GET") -> String {
      var request = URLRequest(url: URL(string: url)!)
      request.httpMethod = method
      return RequestLog.Monitor.describe(request)
    }
    XCTAssertEqual(describe("https://music.lan/rest/getStarred2.view?u=a&t=b"), "rest getStarred2")
    XCTAssertEqual(describe("https://music.lan/rest/ping?u=a"), "rest ping")
    XCTAssertEqual(
      describe("https://music.lan/api/album?_start=0", method: "POST"), "POST /api/album")
    XCTAssertEqual(RequestLog.Monitor.describe(nil), "?")
  }

  func testDiagnosticsRequestDetails() {
    let ok = RequestLog.Entry(
      startedAt: 12.34, text: "rest ping", status: 200, error: nil, duration: 0.42,
      bytes: 0, retries: 0)
    XCTAssertEqual(DiagnosticsReport.details(of: ok), "200 · 0.4 s · +12.3 s")
    let failed = RequestLog.Entry(
      startedAt: 1, text: "GET /api/song", status: 500, error: "Server error", duration: nil,
      bytes: 0, retries: 1)
    XCTAssertEqual(DiagnosticsReport.details(of: failed), "Server error · retry 1 · +1.0 s")
  }
}
