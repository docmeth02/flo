import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class WatchLinkTests: XCTestCase {
  func testPayloadsSurviveTheTrip() {
    let message = Link.Message.signIn(
      Link.SignIn(server: "https://music.lan", user: "u", password: "p", accountKey: "music.lan|id")
    )
    XCTAssertEqual(Link.decode(Link.Message.self, from: Link.encode(message)), message)

    let reply = Link.Reply.otherAccount(user: "v", host: "music.lan")
    XCTAssertEqual(Link.decode(Link.Reply.self, from: Link.encode(reply)), reply)

    var state = Link.WatchState()
    state.account = .init(user: "u", host: "music.lan", key: "music.lan|id")
    state.collections = [.init(id: "a1", name: "Album", songs: 9, kbps: 192)]
    state.incoming = ["a2": 3]
    XCTAssertEqual(Link.decode(Link.WatchState.self, from: Link.encode(state)), state)

    var song = Song(
      id: "s1", title: "Title", albumId: "a1", albumName: "Album", artist: "Artist",
      trackNumber: 2, discNumber: 1, bitRate: 900, sampleRate: 44100, suffix: "flac",
      duration: 201, mediaFileId: "m1")
    song.artistId = "ar1"
    var album = Album()
    album.id = "a1"
    album.name = "Album"
    album.albumArtist = "Artist"
    let info = Link.FileInfo(
      kind: .song, accountKey: "music.lan|id", collectionId: "a1", songCount: 9, album: album,
      song: song, suffix: "mp3", kbps: 192)
    let decoded = Link.decode(Link.FileInfo.self, from: Link.encode(info))
    XCTAssertEqual(decoded, info)
    XCTAssertEqual(decoded?.song?.mediaFileId, "m1")
    XCTAssertEqual(decoded?.song?.artistId, "ar1")
  }

  /// Anything else in a dictionary reads as nothing rather than as a default.
  func testForeignDictionariesDecodeToNothing() {
    XCTAssertNil(Link.decode(Link.PhoneState.self, from: [:]))
    XCTAssertNil(Link.decode(Link.PhoneState.self, from: ["payload": "text"]))
    XCTAssertNil(Link.decode(Link.PhoneState.self, from: ["payload": Data("{}".utf8)]))
    let phone = Link.PhoneState(
      share: true, streamingBitRate: "160", downloadBitRate: "0", keepPlaying: false,
      downloadOverCellular: true,
      sending: ["a1": 9])
    XCTAssertEqual(Link.decode(Link.PhoneState.self, from: Link.encode(phone)), phone)
    XCTAssertNil(Link.decode(Link.FileInfo.self, from: Link.encode(phone)))
  }

  /// A phone of an older build leaves out the newer fields.
  func testOlderPhoneStateDecodes() throws {
    let older = #"""
      {"share":true,"streamingBitRate":"192","downloadBitRate":"0","keepPlaying":true,
      "sending":{"a1":3}}
      """#
    let phone = try XCTUnwrap(
      Link.decode(Link.PhoneState.self, from: ["payload": Data(older.utf8)]))
    XCTAssertNil(phone.showMixReasons)
    XCTAssertNil(phone.mixVariety)
    XCTAssertEqual(phone.sending, ["a1": 3])

    var newer = phone
    newer.showMixReasons = false
    XCTAssertEqual(Link.decode(Link.PhoneState.self, from: Link.encode(newer)), newer)
  }
}
