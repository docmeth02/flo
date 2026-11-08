import CoreData
import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class ModelTests: XCTestCase {
  /// Subsonic answers a failure with HTTP 200 and no lists, which must not
  /// read as nothing liked.
  func testFailedStarredAnswerIsAFailure() throws {
    func decode(_ json: String) throws -> SubsonicEnvelope<Starred2> {
      try JSONDecoder().decode(SubsonicEnvelope<Starred2>.self, from: Data(json.utf8))
    }
    let failed = try decode(
      #"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong password"}}}"#)
    XCTAssertEqual(failed.failure?.code, 40)
    XCTAssertNil(failed.data)
    XCTAssertThrowsError(try failed.payload { $0?.songs ?? [] })

    let ok = try decode(
      #"{"subsonic-response":{"status":"ok","starred2":{"album":[{"id":"al"}]}}}"#)
    XCTAssertNil(ok.failure)
    XCTAssertEqual(ok.data?.collections.albums, ["al"])
    XCTAssertEqual(try ok.payload { $0?.collections.albums }, ["al"])

    XCTAssertEqual(SubsonicError(status: "failed", error: nil)?.code, 0)
    XCTAssertNil(SubsonicError(status: "ok", error: nil))
  }

  /// A song downloaded with a playlist keeps its own album; a record from
  /// before model 6 only knows the collection.
  func testDownloadedSongKeepsItsAlbum() {
    let container = CoreDataManager.inMemoryContainer()
    let entity = SongEntity(context: container.viewContext)
    entity.id = "pl:pl-1:m1"
    entity.albumId = "pl-1"
    entity.songAlbumId = "al-1"
    XCTAssertEqual(Song(from: entity).albumId, "al-1")
    entity.songAlbumId = nil
    XCTAssertEqual(Song(from: entity).albumId, "pl-1")
  }

  /// An album screen shows the downloaded songs with the server's others,
  /// in disc and track order.
  func testAlbumSongsMergeInDiscAndTrackOrder() {
    let local = [Song.fixture("b", disc: 1, track: 2), Song.fixture("c", disc: 2, track: 1)]
    let remote = [
      Song.fixture("c", disc: 2, track: 1), Song.fixture("a", disc: 1, track: 1),
      Song.fixture("b", disc: 1, track: 2), Song.fixture("d", disc: 2, track: 2),
    ]
    XCTAssertEqual(
      AlbumViewModel.mergeAlbumSongs(local: local, remote: remote).map(\.id), ["a", "b", "c", "d"])
    XCTAssertEqual(AlbumViewModel.mergeAlbumSongs(local: local, remote: []).map(\.id), ["b", "c"])
  }

  /// A playlist keeps the server's order, a song it holds twice and its
  /// downloads in place; a download it no longer holds goes last.
  func testPlaylistSongsKeepTheServerOrder() {
    let local = [
      Song.fixture("pl:p:m2", mediaFileId: "m2"), Song.fixture("pl:p:m9", mediaFileId: "m9"),
    ]
    let remote = [
      Song.fixture("m1", mediaFileId: "m1"), Song.fixture("m2", mediaFileId: "m2"),
      Song.fixture("m2", mediaFileId: "m2"),
    ]
    XCTAssertEqual(
      AlbumViewModel.mergePlaylistSongs(local: local, remote: remote).map(\.id),
      ["m1", "pl:p:m2", "m2", "pl:p:m9"])
  }

  /// Off first, then rising to the most the device has room for, with the
  /// default among them.
  func testStreamCacheLimits() {
    let bytes = StreamCacheManager.cacheLimits.map(\.bytes)
    XCTAssertEqual(bytes.first, 0)
    XCTAssertEqual(bytes, bytes.sorted())
    XCTAssertEqual(bytes.last, AppPlatform.largestStreamCache)
    XCTAssertTrue(bytes.contains(524_288_000))
  }

  /// Go to Album and Go to Artist lead anywhere but the screen they are on;
  /// an album names its own artist, a compilation's track artist only
  /// without one.
  func testGoToRulesLeaveOutTheScreenShown() {
    var song = Song.fixture("s", album: "al1")
    song.artistId = "ar1"
    let target = MenuTarget.song(song, context: "", isFromPlaylist: false)
    XCTAssertTrue(target.offersAlbum(except: nil))
    XCTAssertFalse(target.offersAlbum(except: "al1"))
    XCTAssertTrue(target.offersArtist(except: "al1"))
    XCTAssertFalse(target.offersArtist(except: "ar1"))

    let compilation = MenuTarget.album(
      Album(id: "al2", albumArtist: "Various", artist: "Band", artistId: "ar2"))
    XCTAssertEqual(compilation.carriedArtistId, "ar2")
    XCTAssertEqual(compilation.carriedArtistName, "Band")
    XCTAssertFalse(compilation.offersArtist(except: "ar2"))
    XCTAssertFalse(compilation.offersAlbum(except: nil))
    // A downloaded playlist keeps no artist.
    XCTAssertFalse(MenuTarget.album(Album(id: "pl-1")).offersArtist(except: nil))
  }

  /// A playlist's screen counts the songs loaded, else the server's counts.
  func testPlaylistMetaLine() {
    var playlist = Playlist(id: "p", name: "Mix")
    XCTAssertEqual(playlist.meta(loaded: []), "Playlist")
    playlist.songCount = 3
    playlist.duration = 960
    XCTAssertEqual(playlist.meta(loaded: []), "Playlist · 3 songs · 16 min")
    XCTAssertEqual(playlist.meta(loaded: [.fixture("a")]), "Playlist · 1 song · 3 min")
  }
}
