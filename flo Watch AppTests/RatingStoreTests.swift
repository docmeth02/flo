import XCTest

@testable import flo_Watch_App

@MainActor
final class RatingStoreTests: XCTestCase {
  private var reachable = false
  private var answers: [(Result<Void, Error>) -> Void] = []

  private func makeStore(defaults: UserDefaults? = nil) -> RatingStore {
    RatingStore(
      defaults: defaults ?? makeDefaults(), canSend: { [unowned self] in self.reachable },
      send: { [unowned self] _, _, completion in self.answers.append(completion) })
  }

  private func makeDefaults() -> UserDefaults {
    let name = "RatingStoreTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  private func song(
    _ id: String, album: String, rating: Int? = nil, artist: String = "Artist",
    artistId: String? = nil
  ) -> Song {
    var song = Song(
      id: id, title: id, albumId: album, albumName: album, artist: artist, trackNumber: 1,
      discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3", duration: 200,
      mediaFileId: "")
    song.rating = rating
    song.artistId = artistId
    return song
  }

  private func album(_ id: String, rating: Int?) -> Album {
    var album = Album(id: id, name: id)
    album.rating = rating
    return album
  }

  private func artist(_ id: String, rating: Int?) -> Artist {
    var artist = Artist(id: id, name: id, albumCount: 1, mbzArtistID: nil)
    artist.rating = rating
    return artist
  }

  /// The mix's ratings of `songs`, with `keys` mapping artist ids to identities.
  private func mixRatings(
    _ store: RatingStore, _ songs: [Song], keys: [String: String] = [:]
  ) -> [String: MixRanker.Rating] {
    let index = SmartPlaybackService.LibraryIndex(
      songs: Dictionary(
        uniqueKeysWithValues: songs.map { ($0.playbackID, .init($0, artistKeys: keys)) }))
    return SmartPlaybackService.effectiveRatings(of: songs, index: index, store: store)
  }

  func testSongRatingWinsOverItsAlbum() {
    let store = makeStore()
    let s1 = song("s1", album: "a1", rating: 4)
    store.adoptServer(songs: [s1], albums: [album("a1", rating: 2)], artists: [])
    XCTAssertEqual(mixRatings(store, [s1])["s1"], .init(stars: 4, source: .song))

    store.set(1, playbackID: "s1")
    XCTAssertEqual(mixRatings(store, [s1])["s1"], .init(stars: 1, source: .song))
  }

  func testClearingASongRatingFallsBackToItsAlbum() {
    let store = makeStore()
    let s1 = song("s1", album: "a1", rating: 4)
    store.adoptServer(songs: [s1], albums: [album("a1", rating: 2)], artists: [])
    store.set(0, playbackID: "s1")
    XCTAssertEqual(mixRatings(store, [s1])["s1"], .init(stars: 2, source: .album))
  }

  func testUnratedSongTakesItsAlbumRating() {
    let store = makeStore()
    let songs = [song("s1", album: "a1", rating: 0), song("s2", album: "a1")]
    store.adoptServer(songs: songs, albums: [album("a1", rating: 5)], artists: [])
    XCTAssertEqual(mixRatings(store, songs)["s1"], .init(stars: 5, source: .album))
    XCTAssertEqual(mixRatings(store, songs)["s2"], .init(stars: 5, source: .album))
  }

  func testNothingRatedIsZero() {
    let store = makeStore()
    store.adoptServer(
      songs: [], albums: [album("a1", rating: 0), album("a2", rating: nil)],
      artists: [artist("ar1", rating: nil)])
    let songs = [song("s1", album: "a1", artistId: "ar1"), song("s2", album: "a2")]
    XCTAssertTrue(mixRatings(store, songs).isEmpty)
    XCTAssertEqual(store.artistRating("ar1"), 0)
  }

  /// The order is the song's own rating, its album's, then its artist's.
  func testAnArtistRatingStandsInForUnratedSongsAndAlbums() {
    let store = makeStore()
    let songs = [
      song("s1", album: "a1", rating: 3, artistId: "ar1"),
      song("s2", album: "a2", artistId: "ar1"),
      song("s3", album: "a3", artistId: "ar1"),
    ]
    store.adoptServer(
      songs: songs, albums: [album("a2", rating: 4)], artists: [artist("ar1", rating: 1)])
    let ratings = mixRatings(store, songs)
    XCTAssertEqual(ratings["s1"], .init(stars: 3, source: .song))
    XCTAssertEqual(ratings["s2"], .init(stars: 4, source: .album))
    XCTAssertEqual(ratings["s3"], .init(stars: 1, source: .artist))
  }

  /// A rating of one spelling covers the others of the same identity; where
  /// spellings disagree, the lowest wins.
  func testAnArtistRatingCoversItsOtherSpellings() {
    let store = makeStore()
    let songs = [
      song("s1", album: "a1", artist: "BABYMETAL", artistId: "ar1"),
      song("s2", album: "a2", artist: "Baby Metal", artistId: "ar2"),
      song("s3", album: "a3", artist: "Other", artistId: "ar3"),
    ]
    let keys = ["ar1": "name:babymetal", "ar2": "name:babymetal", "ar3": "ar3"]
    store.adoptServer(songs: [], albums: [], artists: [artist("ar2", rating: 5)])
    var ratings = mixRatings(store, songs, keys: keys)
    XCTAssertEqual(ratings["s1"], .init(stars: 5, source: .artist))
    XCTAssertEqual(ratings["s2"], .init(stars: 5, source: .artist))
    XCTAssertNil(ratings["s3"])

    store.setArtist(1, artistId: "ar1")
    ratings = mixRatings(store, songs, keys: keys)
    XCTAssertEqual(ratings["s2"], .init(stars: 1, source: .artist))
  }

  /// An artist edit never reads as a song's rating, and a refresh that does
  /// not know it yet keeps it while it waits.
  func testAPendingArtistRatingIsKeptApartFromSongs() {
    let store = makeStore()
    store.setArtist(5, artistId: "ar1")
    XCTAssertEqual(store.artistRating("ar1"), 5)
    XCTAssertTrue(store.isPending("ar1"))
    XCTAssertEqual(store.rating(for: "ar1"), 0)
    XCTAssertTrue(store.ratings.isEmpty)

    store.adoptServer(songs: [], albums: [], artists: [])
    XCTAssertEqual(store.artistRating("ar1"), 5)
    XCTAssertEqual(store.artistRatings, ["ar1": 5])
  }

  /// A taken artist rating survives a relaunch until a refresh, which is
  /// newer whatever it says.
  func testAConfirmedArtistRatingLastsUntilARefresh() async {
    reachable = true
    let defaults = makeDefaults()
    let store = makeStore(defaults: defaults)
    store.setArtist(4, artistId: "ar1")
    answers[0](.success(()))
    for _ in 0..<5 { await Task.yield() }
    XCTAssertFalse(store.isPending("ar1"))
    XCTAssertEqual(store.artistRating("ar1"), 4)

    let relaunched = makeStore(defaults: defaults)
    XCTAssertEqual(relaunched.artistRating("ar1"), 4)
    XCTAssertTrue(relaunched.ratings.isEmpty)

    relaunched.adoptServer(songs: [], albums: [], artists: [artist("ar1", rating: 2)])
    XCTAssertEqual(relaunched.artistRating("ar1"), 2)
  }

  func testLogoutDropsArtistRatings() {
    let store = makeStore()
    store.adoptServer(songs: [], albums: [], artists: [artist("ar1", rating: 5)])
    store.setArtist(1, artistId: "ar2")
    store.forgetAccount()
    XCTAssertEqual(store.artistRating("ar1"), 0)
    XCTAssertEqual(store.artistRating("ar2"), 0)
    XCTAssertFalse(store.isPending("ar2"))
  }

  func testArtistDecodesItsRating() throws {
    func decode(_ field: String) throws -> Artist {
      let json = #"{"id":"ar1","name":"A","albumCount":1\#(field)}"#
      return try JSONDecoder().decode(Artist.self, from: Data(json.utf8))
    }
    XCTAssertEqual(try decode(#","rating":5"#).rating, 5)
    XCTAssertNil(try decode("").rating)
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
