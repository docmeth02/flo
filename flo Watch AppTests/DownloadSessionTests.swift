import XCTest

@testable import flo_Watch_App

final class DownloadSessionTests: XCTestCase {
  private func song(_ id: String, mediaFileId: String) -> Song {
    Song(
      id: id, title: "Song \(id)", albumId: "al", albumName: "Album", artist: "Artist",
      trackNumber: 1, discNumber: 1, bitRate: 900, sampleRate: 44100, suffix: "flac",
      duration: 200, mediaFileId: mediaFileId)
  }

  func testPlaylistDuplicateIsOneJobAndCountsOnce() {
    // Playlist entries have their own ids; the media file is what is fetched.
    let playlist = Album(
      id: "pl", name: "Mix",
      songs: [
        song("1", mediaFileId: "m1"), song("2", mediaFileId: "m2"), song("3", mediaFileId: "m1"),
      ])
    let jobs = DownloadJob.jobs(for: playlist, isPlaylist: true, kbps: 192, downloaded: [])
    XCTAssertEqual(jobs.map(\.id), ["pl:m1", "pl:m2"])
    XCTAssertEqual(jobs.map(\.playlistIndex), [0, 1])
    XCTAssertEqual(jobs.map(\.suffix), ["mp3", "mp3"])

    let batch = Set(jobs.map(\.id))
    XCTAssertEqual(DownloadProgress.fraction(batch: batch, pending: batch), 0)
    XCTAssertEqual(DownloadProgress.fraction(batch: batch, pending: ["pl:m2"]), 0.5)
    XCTAssertEqual(DownloadProgress.fraction(batch: batch, pending: []), 1)
    XCTAssertEqual(DownloadProgress.fraction(batch: [], pending: []), 0)
  }

  func testDownloadedSongsAreSkipped() {
    let album = Album(
      id: "al", name: "Album", songs: [song("a", mediaFileId: "a"), song("b", mediaFileId: "b")])
    let jobs = DownloadJob.jobs(for: album, isPlaylist: false, kbps: 0, downloaded: ["a"])
    XCTAssertEqual(jobs.map(\.id), ["al:b"])
    XCTAssertEqual(jobs.first?.suffix, "flac")
    XCTAssertEqual(jobs.first?.playlistIndex, -1)
  }

  func testConnectionErrorsGoAgainUncounted() {
    let connection: [URLError.Code] = [
      .networkConnectionLost, .timedOut, .notConnectedToInternet, .cancelled,
      .secureConnectionFailed,
    ]
    for code in connection {
      XCTAssertEqual(DownloadFailure.classify(error: URLError(code)), .connection, "\(code)")
    }
    XCTAssertEqual(DownloadFailure.classify(error: URLError(.serverCertificateUntrusted)), .counted)
  }

  func testResponsesAreClassified() {
    func classify(_ status: Int, errorBody: Bool = false, code: Int? = nil, bytes: Int64 = 4096)
      -> DownloadFailure?
    {
      DownloadFailure.classify(
        status: status, isErrorBody: errorBody, subsonicCode: code, bytes: bytes)
    }
    XCTAssertNil(classify(200))
    XCTAssertEqual(classify(503), .counted)
    XCTAssertEqual(classify(200, bytes: 0), .counted)
    XCTAssertEqual(classify(200, errorBody: true, code: 70), .counted)
    XCTAssertEqual(classify(200, errorBody: true), .counted)
    XCTAssertEqual(classify(200, errorBody: true, code: 40), .final)
  }

  func testBackoffThenFailed() {
    XCTAssertEqual(DownloadRetry.delay(afterAttempts: 0), 30)
    XCTAssertEqual(DownloadRetry.delay(afterAttempts: 1), 120)
    XCTAssertEqual(DownloadRetry.delay(afterAttempts: 2), 300)
    XCTAssertNil(DownloadRetry.delay(afterAttempts: 3))
  }

  func testJobStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
    XCTAssertEqual(store.load(), [])

    let album = Album(
      id: "al", name: "Album", songs: [song("a", mediaFileId: "a"), song("b", mediaFileId: "b")])
    var jobs = DownloadJob.jobs(for: album, isPlaylist: false, kbps: 192, downloaded: [])
    jobs[0].attempts = 2
    jobs[0].retryAt = Date(timeIntervalSince1970: 1_800_000_000)
    jobs[1].failed = true
    jobs[1].startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    store.save(jobs)
    XCTAssertEqual(store.load(), jobs)
  }
}
