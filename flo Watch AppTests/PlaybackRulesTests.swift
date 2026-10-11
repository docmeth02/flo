import Alamofire
import CoreData
import XCTest

@testable import flo_Watch_App

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
    // The app's model: a second copy of it makes the entity classes ambiguous.
    let container = NSPersistentContainer(
      name: "flo", managedObjectModel: CoreDataManager.shared.persistentContainer.managedObjectModel)
    let store = NSPersistentStoreDescription()
    store.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [store]
    container.loadPersistentStores { _, error in XCTAssertNil(error) }

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
