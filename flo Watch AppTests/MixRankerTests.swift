import XCTest

@testable import flo_Watch_App

final class MixRankerTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  /// Ten artists with six songs each over two albums and four genres.
  private func library() -> [Song] {
    (0..<10).flatMap { artist in
      (0..<6).map { track in
        var song = Song(
          id: "s\(artist)-\(track)", title: "Song \(artist)-\(track)", albumId: "a\(artist)-\(track % 2)",
          albumName: "Album \(artist)-\(track % 2)", artist: "Artist \(artist)",
          trackNumber: track + 1, discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3",
          duration: 200, mediaFileId: "")
        song.artistId = "ar\(artist)"
        song.genre = "Genre \(artist % 4)"
        song.year = 1990 + artist
        song.playCount = (artist + track) % 5
        return song
      }
    }
  }

  private func mix(seed: UInt64, count: Int = 15) -> [Song] {
    let songs = library()
    let index = SmartPlaybackService.LibraryIndex(
      songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.playbackID, .init($0)) }))
    var rng = SplitMix64(seed: seed)
    return MixRanker().rank(
      library: songs, index: index, affinity: AffinitySnapshot(), journal: JournalSnapshot(),
      pendingPlays: [:], ratings: [:], starred: [], mode: .playSomething, count: count, now: now,
      rng: &rng
    ).songs
  }

  /// The score line of the first song ranked alone.
  private func scores(
    journal: JournalSnapshot = JournalSnapshot(), pendingPlays: [String: Date] = [:],
    ratings: [String: MixRanker.Rating] = [:]
  ) -> String? {
    let song = library()[0]
    let index = SmartPlaybackService.LibraryIndex(songs: [song.playbackID: .init(song)])
    var rng = SplitMix64(seed: 1)
    return MixRanker().rank(
      library: [song], index: index, affinity: AffinitySnapshot(), journal: journal,
      pendingPlays: pendingPlays, ratings: ratings, starred: [], mode: .playSomething, count: 1,
      now: now, rng: &rng
    ).record.picks.first?.scores
  }

  func testSameSeedGivesTheSameMix() {
    XCTAssertEqual(mix(seed: 7).map(\.id), mix(seed: 7).map(\.id))
  }

  func testMixHasTheCountWithoutRepeats() {
    let songs = mix(seed: 3)
    XCTAssertEqual(songs.count, 15)
    XCTAssertEqual(Set(songs.map(\.id)).count, songs.count)
  }

  func testNoArtistExceedsTheCap() {
    let cap = MixRanker.Config().perArtistCap
    for seed in 1...20 {
      let perArtist = Dictionary(grouping: mix(seed: UInt64(seed)), by: \.artist)
      XCTAssertLessThanOrEqual(perArtist.values.map(\.count).max() ?? 0, cap, "seed \(seed)")
    }
  }

  func testSkipLoadHalvesEveryHalfLife() {
    let ranker = MixRanker()
    let halfLife = ranker.config.skipHalfLife
    let fresh = JournalSnapshot.SkipEvent(at: now, weight: 1, artistKey: "")
    let old = JournalSnapshot.SkipEvent(at: now.addingTimeInterval(-halfLife), weight: 1, artistKey: "")
    XCTAssertEqual(ranker.skipLoad([fresh], now: now), 1, accuracy: 1e-9)
    XCTAssertEqual(ranker.skipLoad([old], now: now), 0.5, accuracy: 1e-9)
  }

  func testSpreadArtistsMovesBackToBackSongsApart() {
    let spread = MixRanker.spreadArtists(["A", "A", "B", "C"], after: "C") { $0 }
    XCTAssertEqual(spread, ["A", "B", "A", "C"])
    XCTAssertNotEqual(MixRanker.spreadArtists(["C", "D"], after: "C") { $0 }.first, "C")
  }

  func testArtistAffinityIsSummedPerArtistKey() {
    let earlier = Date(timeIntervalSince1970: 100)
    let latest = Date(timeIntervalSince1970: 200)
    var president = library()[0]
    president.artistId = "ar1"
    var shouting = library()[1]
    shouting.artistId = "ar2"
    let keys = ["ar1": "name:president", "ar2": "name:president"]
    let index = SmartPlaybackService.LibraryIndex(songs: [
      president.playbackID: .init(president, artistKeys: keys),
      shouting.playbackID: .init(shouting, artistKeys: keys),
    ])
    let stored: [String: AffinitySnapshot.Aggregate] = [
      "ar1": .init(weight: 2, lastPlayAt: latest, plays: 3),
      "ar2": .init(weight: 1.5, lastPlayAt: earlier, plays: 2),
      "ar9": .init(weight: 1, lastPlayAt: nil, plays: 1),
    ]
    let groups = MixRanker.artistAffinity(stored, index: index)
    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups["name:president"]?.weight ?? 0, 3.5, accuracy: 1e-9)
    XCTAssertEqual(groups["name:president"]?.plays, 5)
    XCTAssertEqual(groups["name:president"]?.lastPlayAt, latest)
    XCTAssertEqual(groups["ar9"]?.plays, 1)
  }

  func testAnOutboxPlayCoolsASongDownOnceAndAddsNoPlays() throws {
    let id = library()[0].playbackID
    let heard = now.addingTimeInterval(-3600)
    var journal = JournalSnapshot()
    journal.lastHeardAt[id] = heard

    let fresh = try XCTUnwrap(scores())
    let outbox = try XCTUnwrap(scores(pendingPlays: [id: heard]))
    XCTAssertNotEqual(outbox, fresh)
    XCTAssertEqual(outbox, scores(journal: journal))
    XCTAssertEqual(outbox, scores(journal: journal, pendingPlays: [id: heard]))
    // An older outbox play leaves the journal's newer one in charge.
    XCTAssertEqual(
      outbox, scores(journal: journal, pendingPlays: [id: heard.addingTimeInterval(-7200)]))
  }

  func testLatestListensKeepTheNewestPerSong() {
    let early = Date(timeIntervalSince1970: 100)
    let late = Date(timeIntervalSince1970: 200)
    let latest = SmartPlaybackService.latestListens([
      (songId: "s1", at: late), (songId: "s1", at: early), (songId: "s2", at: early),
    ])
    XCTAssertEqual(latest, ["s1": late, "s2": early])
  }

  func testAnAlbumRatingShowsAsTheAlbums() throws {
    let id = library()[0].playbackID
    let own = try XCTUnwrap(scores(ratings: [id: .init(stars: 5, fromAlbum: false)]))
    let album = try XCTUnwrap(scores(ratings: [id: .init(stars: 5, fromAlbum: true)]))
    XCTAssertTrue(own.contains("rating=5+.35"), own)
    XCTAssertTrue(album.contains("rating=5(album)+.35"), album)
    XCTAssertNil(scores(ratings: [id: .init(stars: 1, fromAlbum: true)]))
  }
}
