import XCTest

@testable import flo_Watch_App

@MainActor
final class RatingStoreTests: XCTestCase {
  private func makeStore() -> RatingStore {
    let name = "RatingStoreTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return RatingStore(
      defaults: UserDefaults(suiteName: name)!, canSend: { false }, send: { _, _, _ in })
  }

  private func song(_ id: String, album: String, rating: Int? = nil) -> Song {
    var song = Song(
      id: id, title: id, albumId: album, albumName: album, artist: "Artist", trackNumber: 1,
      discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3", duration: 200,
      mediaFileId: "")
    song.rating = rating
    return song
  }

  private func album(_ id: String, rating: Int?) -> Album {
    var album = Album(id: id, name: id)
    album.rating = rating
    return album
  }

  func testSongRatingWinsOverItsAlbum() {
    let store = makeStore()
    store.adoptServer(songs: [song("s1", album: "a1", rating: 4)], albums: [album("a1", rating: 2)])
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a1"), 4)

    store.set(1, playbackID: "s1")
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a1"), 1)
  }

  func testClearingASongRatingFallsBackToItsAlbum() {
    let store = makeStore()
    store.adoptServer(songs: [song("s1", album: "a1", rating: 4)], albums: [album("a1", rating: 2)])
    store.set(0, playbackID: "s1")
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a1"), 2)
  }

  func testUnratedSongTakesItsAlbumRating() {
    let store = makeStore()
    store.adoptServer(songs: [song("s1", album: "a1", rating: 0)], albums: [album("a1", rating: 5)])
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a1"), 5)
    XCTAssertEqual(store.effectiveRating(songId: "s2", albumId: "a1"), 5)
  }

  func testNothingRatedIsZero() {
    let store = makeStore()
    store.adoptServer(songs: [], albums: [album("a1", rating: 0), album("a2", rating: nil)])
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a1"), 0)
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: "a2"), 0)
    XCTAssertEqual(store.effectiveRating(songId: "s1", albumId: nil), 0)
  }

  func testAlbumDecodesItsRating() throws {
    func decode(_ rating: String?) throws -> Album {
      let field = rating.map { #","rating":\#($0)"# } ?? ""
      let json = #"{"id":"a1","name":"A","albumArtist":"B","genre":"","minYear":0\#(field)}"#
      return try JSONDecoder().decode(Album.self, from: Data(json.utf8))
    }
    XCTAssertEqual(try decode("3").rating, 3)
    XCTAssertNil(try decode("null").rating)
    XCTAssertNil(try decode(nil).rating)

    // The library cache keeps it.
    let cached = try JSONDecoder().decode(
      Album.self, from: JSONEncoder().encode(try decode("4")))
    XCTAssertEqual(cached.rating, 4)
  }
}
