import XCTest

@testable import flo_Watch_App

final class LibrarySearchTests: XCTestCase {
  private func artist(_ id: String, _ name: String) throws -> Artist {
    try JSONDecoder().decode(Artist.self, from: Data(#"{"id":"\#(id)","name":"\#(name)"}"#.utf8))
  }

  private func album(_ id: String, _ name: String, by artist: String) -> Album {
    Album(id: id, name: name, albumArtist: artist)
  }

  private func song(_ id: String, _ title: String, by artist: String, on album: String) -> Song {
    Song(
      id: id, title: title, albumId: "al-\(album)", albumName: album, artist: artist,
      trackNumber: 1, discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3",
      duration: 200, mediaFileId: id)
  }

  private func search(
    _ query: String, artists: [Artist] = [], albums: [Album] = [], songs: [Song] = []
  ) -> LibrarySearch.Results? {
    LibrarySearch.search(query, artists: artists, albums: albums, songs: songs)
  }

  func testIgnoresCaseAndAccents() throws {
    let artists = [try artist("1", "Björk"), try artist("2", "Sigur Rós")]
    XCTAssertEqual(search("bjork", artists: artists)?.artists.map(\.id), ["1"])
    XCTAssertEqual(search("ROS", artists: artists)?.artists.map(\.id), ["2"])
    XCTAssertEqual(search("  Björk ", artists: artists)?.artists.map(\.id), ["1"])
  }

  func testMatchesTheDocumentedFields() {
    let albums = [album("a1", "Homogenic", by: "Björk"), album("a2", "Takk", by: "Sigur Rós")]
    XCTAssertEqual(search("sigur", albums: albums)?.albums.map(\.id), ["a2"])
    let songs = [
      song("s1", "Jóga", by: "Björk", on: "Homogenic"),
      song("s2", "Hoppípolla", by: "Sigur Rós", on: "Takk"),
    ]
    XCTAssertEqual(search("joga", songs: songs)?.songs.map(\.id), ["s1"])
    XCTAssertEqual(search("sigur", songs: songs)?.songs.map(\.id), ["s2"])
    XCTAssertEqual(search("homogenic", songs: songs)?.songs.map(\.id), ["s1"])
    XCTAssertEqual(search("nothing like this", albums: albums, songs: songs)?.isEmpty, true)
  }

  func testNamesStartingWithTheQueryComeFirst() {
    let songs = [
      song("s1", "Glove", by: "A", on: "B"),
      song("s2", "Track", by: "A", on: "Love"),
      song("s3", "Lovesong", by: "A", on: "B"),
    ]
    XCTAssertEqual(search("love", songs: songs)?.songs.map(\.id), ["s3", "s1", "s2"])
  }

  func testResultsAreCapped() throws {
    let artists = try (0..<20).map { try artist("ar\($0)", "Band \($0)") }
    let albums = (0..<20).map { album("al\($0)", "Record \($0)", by: "Band") }
    let songs = (0..<40).map { song("s\($0)", "Tune \($0)", by: "Band", on: "Record") }
    let results = search("band", artists: artists, albums: albums, songs: songs)
    XCTAssertEqual(results?.artists.count, LibrarySearch.artistLimit)
    XCTAssertEqual(results?.albums.count, LibrarySearch.albumLimit)
    XCTAssertEqual(results?.songs.count, LibrarySearch.songLimit)
    // Within a rank the list's order is kept.
    XCTAssertEqual(results?.songs.first?.id, "s0")
  }

  func testABlankQuerySearchesNothing() throws {
    let artists = [try artist("1", "Björk")]
    XCTAssertNil(search("", artists: artists))
    XCTAssertNil(search("   ", artists: artists))
  }
}
