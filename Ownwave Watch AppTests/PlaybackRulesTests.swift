import Alamofire
import CoreData
import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class PlaybackRulesTests: XCTestCase {
  private func status(_ code: Int) -> AFError {
    .responseValidationFailed(reason: .unacceptableStatusCode(code: code))
  }

  func testOnlyRejectionsDropAScrobble() {
    let service = FloooService.shared
    XCTAssertTrue(service.isPermanentFailure(SubsonicError(code: 10, message: nil)))
    XCTAssertTrue(service.isPermanentFailure(SubsonicError(code: 70, message: nil)))
    XCTAssertFalse(service.isPermanentFailure(SubsonicError(code: 0, message: nil)))
    XCTAssertTrue(service.isPermanentFailure(status(404)))
    // Auth, timeouts, throttling and server errors are worth another try.
    for code in [401, 403, 408, 429, 500, 503] {
      XCTAssertFalse(service.isPermanentFailure(status(code)), "\(code)")
    }
    XCTAssertFalse(service.isPermanentFailure(URLError(.notConnectedToInternet)))
  }

  /// The streaming limit follows the network: the Wi-Fi limit off cellular,
  /// the cellular one on it, none when streaming on cellular is off.
  func testStreamingBitRateFollowsTheNetwork() {
    let defaults = UserDefaults.standard
    let keys = [
      UserDefaultsKeys.enableMaxBitRate, UserDefaultsKeys.cellularBitRate,
      UserDefaultsKeys.streamOnCellular,
    ]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

    UserDefaultsManager.maxBitRate = "320"
    UserDefaultsManager.cellularBitRate = "160"
    defaults.removeObject(forKey: UserDefaultsKeys.streamOnCellular)
    XCTAssertEqual(TranscodingSettings.streamingBitRate(onCellular: false), "320")
    XCTAssertEqual(TranscodingSettings.streamingBitRate(onCellular: true), "160")
    XCTAssertTrue(TranscodingSettings.streamsOverCellular)
    UserDefaultsManager.streamOnCellular = false
    XCTAssertNil(TranscodingSettings.streamingBitRate(onCellular: true))
    XCTAssertEqual(TranscodingSettings.streamingBitRate(onCellular: false), "320")
    XCTAssertFalse(TranscodingSettings.streamsOverCellular)
  }

  /// Only Navidrome's own answer to a login logs out; a bare 401 from a proxy
  /// and a lost connection keep the session.
  func testLoginErrors() {
    let body = Data(#"{"error":"Invalid username or password"}"#.utf8)
    XCTAssertEqual(
      AuthError(login: status(401), body: body),
      .invalidCredentials(message: "Invalid username or password"))
    XCTAssertEqual(AuthError(login: status(500), body: body), .server(message: "Invalid username or password"))
    XCTAssertEqual(AuthError(login: status(401), body: Data("<html>".utf8)), .sessionExpired)
    XCTAssertEqual(AuthError(login: status(403), body: nil), .sessionExpired)
    let offline = URLError(.notConnectedToInternet)
    XCTAssertEqual(
      AuthError(login: .sessionTaskFailed(error: offline), body: nil),
      .server(message: offline.localizedDescription))
    XCTAssertEqual(AuthError(login: status(502), body: nil), .unknown)
  }

  /// A dead zone is asked once more and then waited out; only the server's
  /// own verdict on the song skips it.
  func testDecisionFailuresSortIntoRetryWaitAndSkip() {
    func classify(status: Int? = nil, _ error: Error? = nil, subsonicError: Bool = false)
      -> DecisionFailure
    {
      DecisionFailure.classify(status: status, error: error, subsonicError: subsonicError)
    }
    let transientErrors: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost,
      .cannotConnectToHost, .dnsLookupFailed,
    ]
    for code in transientErrors {
      XCTAssertEqual(classify(URLError(code)), .transient, "\(code)")
    }
    for code in [408, 429, 500, 502, 503, 504] {
      XCTAssertEqual(classify(status: code), .transient, "\(code)")
    }

    // Not worth a second request, but no reason to skip the song either.
    for code in [401, 403, 404, 200] {
      XCTAssertEqual(classify(status: code), .unavailable, "\(code)")
    }
    let lastingErrors: [URLError.Code] = [
      .cancelled, .serverCertificateUntrusted, .secureConnectionFailed, .badServerResponse,
    ]
    for code in lastingErrors {
      XCTAssertEqual(classify(URLError(code)), .unavailable, "\(code)")
    }
    XCTAssertEqual(classify(nil), .unavailable)

    XCTAssertEqual(classify(status: 200, subsonicError: true), .unplayable)

    XCTAssertEqual(DecisionFailure.transient.streamFailure, .unavailable)
    XCTAssertEqual(DecisionFailure.unavailable.streamFailure, .unavailable)
    XCTAssertEqual(DecisionFailure.unplayable.streamFailure, .unplayable)
  }

  /// The journal and the ranker tell a song's origin by the queue's name.
  func testQueueNamesMapToOrigins() throws {
    let container = CoreDataManager.inMemoryContainer()

    func origin(_ name: String, playlist: Bool = false) -> PlaybackOrigin {
      let entry = QueueEntity(context: container.viewContext)
      entry.contextName = name
      entry.isFromPlaylist = playlist
      return entry.playbackOrigin
    }
    XCTAssertEqual(origin("Smart Shuffle"), .smartShuffle)
    XCTAssertEqual(origin("Auto Play"), .keepPlaying)
    XCTAssertEqual(origin("Liked Songs"), .starred)
    XCTAssertEqual(origin("Cached"), .cached)
    XCTAssertEqual(origin("Road Trip", playlist: true), .playlist)
    XCTAssertEqual(origin("Some Album"), .album)
  }

  /// The watch keeps a start through its output setup's interruptions, a
  /// bounded number of times; the phone pauses on every interruption.
  func testInterruptionKeepsOnlyAWatchStartUnderWay() {
    typealias Player = PlayerViewModel
    let activating = Player.PendingStart()
    var settled = Player.PendingStart()
    settled.isActivating = false
    var exhausted = Player.PendingStart()
    exhausted.resumes = Player.maxSettleResumes

    XCTAssertTrue(Player.keepsStart(activating, isPlaying: false, platformKeeps: true))
    XCTAssertTrue(Player.keepsStart(settled, isPlaying: true, platformKeeps: true))
    XCTAssertFalse(Player.keepsStart(settled, isPlaying: false, platformKeeps: true))
    XCTAssertFalse(Player.keepsStart(exhausted, isPlaying: true, platformKeeps: true))
    XCTAssertFalse(Player.keepsStart(nil, isPlaying: true, platformKeeps: true))
    XCTAssertFalse(Player.keepsStart(activating, isPlaying: true, platformKeeps: false))
    #if os(watchOS)
      XCTAssertTrue(AppPlatform.keepsStartThroughInterruptions)
    #else
      XCTAssertFalse(AppPlatform.keepsStartThroughInterruptions)
    #endif
  }

  func testBitRatesNoLongerOfferedReadAsTheDefault() {
    XCTAssertEqual(TranscodingSettings.offeredBitRate(nil), "192")
    for rate in ["32", "64", "96", "", "abc"] {
      XCTAssertEqual(TranscodingSettings.offeredBitRate(rate), "192", rate)
    }
    for rate in TranscodingSettings.bitRates {
      XCTAssertEqual(TranscodingSettings.offeredBitRate(rate), rate)
    }
  }
}
