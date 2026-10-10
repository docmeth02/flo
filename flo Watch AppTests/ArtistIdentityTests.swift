import XCTest

@testable import flo_Watch_App

final class ArtistIdentityTests: XCTestCase {
  private func key(_ name: String?, _ mbid: String? = nil) -> String? {
    ArtistIdentity.key(name: name, mbid: mbid)
  }

  private func artist(_ id: String, _ name: String, mbid: String? = nil) throws -> Artist {
    var json: [String: String] = ["id": id, "name": name]
    json["mbzArtistId"] = mbid
    return try JSONDecoder().decode(Artist.self, from: JSONEncoder().encode(json))
  }

  private func song(_ artist: String, artistId: String?) -> Song {
    var song = Song(
      id: "s", title: "Song", albumId: "al", albumName: "Album", artist: artist,
      trackNumber: 1, discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3",
      duration: 200, mediaFileId: "")
    song.artistId = artistId
    return song
  }

  func testSpellingsOfOneNameShareAKey() {
    XCTAssertEqual(key("President"), key("PRESIDENT"))
    XCTAssertEqual(key("BABYMETAL"), key("Baby Metal"))
    XCTAssertEqual(key("ＢＡＢＹＭＥＴＡＬ"), key("BABYMETAL"))
    XCTAssertEqual(key("AC/DC"), key("ACDC"))
    XCTAssertEqual(key("Beyoncé"), key("beyonce"))
    XCTAssertNotEqual(key("Muse"), key("Mute"))
  }

  func testMusicBrainzIdWinsOverTheName() {
    XCTAssertEqual(key("President", "ABC-1"), "mbz:abc-1")
    XCTAssertNotEqual(key("President", "abc-1"), key("President", "abc-2"))
    XCTAssertEqual(key("President", " "), key("President"))
  }

  func testNothingToCompareGivesNoKey() {
    XCTAssertNil(key(nil))
    XCTAssertNil(key(""))
    XCTAssertNil(key("  "))
    XCTAssertNil(key("!?"))
    XCTAssertEqual(key("東京事変"), "name:東京事変")
  }

  func testListedArtistsBorrowTheOnlyMusicBrainzIdOfTheirName() throws {
    let keys = ArtistIdentity.keys(of: [
      try artist("1", "President", mbid: "m1"),
      try artist("2", "PRESIDENT"),
      try artist("3", "Muse", mbid: "m2"),
      try artist("4", "MUSE", mbid: "m3"),
      try artist("5", "muse"),
    ])
    XCTAssertEqual(keys["1"], "mbz:m1")
    XCTAssertEqual(keys["2"], "mbz:m1")
    XCTAssertEqual(keys["3"], "mbz:m2")
    XCTAssertEqual(keys["4"], "mbz:m3")
    XCTAssertEqual(keys["5"], "name:muse")
  }

  func testIsByMatchesTheIdOrTheSpelling() {
    XCTAssertTrue(song("Anything", artistId: "ar1").isBy(artistId: "ar1", name: "President", keys: [:]))
    XCTAssertTrue(song("PRESIDENT", artistId: "ar2").isBy(artistId: "ar1", name: "President", keys: [:]))
    XCTAssertTrue(song("Baby Metal", artistId: nil).isBy(artistId: "ar1", name: "BABYMETAL", keys: [:]))
    XCTAssertFalse(song("Muse", artistId: "ar2").isBy(artistId: "ar1", name: "President", keys: [:]))
    XCTAssertFalse(song("", artistId: nil).isBy(artistId: "ar1", name: "", keys: [:]))
    // MusicBrainz decides over the name: same name, different artists, and
    // one artist under two names.
    let keys = ["ar1": "mbz:a", "ar2": "mbz:b", "ar3": "mbz:a"]
    XCTAssertFalse(song("President", artistId: "ar2").isBy(artistId: "ar1", name: "President", keys: keys))
    XCTAssertTrue(song("Prez", artistId: "ar3").isBy(artistId: "ar1", name: "President", keys: keys))
    // A download keeps no artist id and matches by name.
    XCTAssertTrue(song("PRESIDENT", artistId: nil).isBy(artistId: "ar1", name: "President", keys: keys))
  }

  func testLibraryIndexKeysSongsByIdentityAndHistoryById() {
    let president = song("President", artistId: "ar1")
    var shouting = song("PRESIDENT", artistId: "ar2")
    shouting.mediaFileId = "s2"
    let keys = ["ar1": "name:president", "ar2": "name:president"]
    let index = SmartPlaybackService.LibraryIndex(songs: [
      "s": .init(president, artistKeys: keys), "s2": .init(shouting, artistKeys: keys),
    ])
    XCTAssertEqual(index.songs["s"]?.artistKey, "name:president")
    XCTAssertEqual(index.songs["s2"]?.historyArtistKey, "ar2")
    XCTAssertEqual(index.artistKeys, keys)

    // An artist missing from the list keeps its server id.
    XCTAssertEqual(SmartPlaybackService.LibraryIndex.Entry(president).artistKey, "ar1")
  }
}
