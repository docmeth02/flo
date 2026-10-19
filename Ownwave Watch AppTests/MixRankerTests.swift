import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

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
      pendingPlays: [:], ratings: [:], starred: [], likedAlbums: [], likedArtists: [],
      mode: .playSomething, count: count, now: now, rng: &rng
    ).songs
  }

  /// The first song ranked alone; nil when it is excluded.
  private func pick(
    journal: JournalSnapshot = JournalSnapshot(), pendingPlays: [String: Date] = [:],
    ratings: [String: MixRanker.Rating] = [:], likedAlbums: Set<String> = [],
    likedArtists: Set<String> = []
  ) -> MixRecord.Pick? {
    let song = library()[0]
    let index = SmartPlaybackService.LibraryIndex(songs: [song.playbackID: .init(song)])
    var rng = SplitMix64(seed: 1)
    return MixRanker().rank(
      library: [song], index: index, affinity: AffinitySnapshot(), journal: journal,
      pendingPlays: pendingPlays, ratings: ratings, starred: [], likedAlbums: likedAlbums,
      likedArtists: likedArtists, mode: .playSomething, count: 1, now: now, rng: &rng
    ).record.picks.first
  }

  /// The score line of the first song ranked alone.
  private func scores(
    journal: JournalSnapshot = JournalSnapshot(), pendingPlays: [String: Date] = [:],
    ratings: [String: MixRanker.Rating] = [:]
  ) -> String? {
    pick(journal: journal, pendingPlays: pendingPlays, ratings: ratings)?.scores
  }

  private func song(_ id: String, artist: String, album: String, plays: Int = 0) -> Song {
    var song = Song.fixture(id, artist: artist, album: album, albumName: album)
    song.artistId = "ar-\(artist)"
    song.genre = "Rock"
    song.playCount = plays
    return song
  }

  private func rank(
    _ songs: [Song], ranker: MixRanker = MixRanker(), affinity: AffinitySnapshot = AffinitySnapshot(),
    journal: JournalSnapshot = JournalSnapshot(), ratings: [String: MixRanker.Rating] = [:],
    likedAlbums: Set<String> = [], likedArtists: Set<String> = [], count: Int, seed: UInt64
  ) -> (songs: [Song], record: MixRecord) {
    let index = SmartPlaybackService.LibraryIndex(
      songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.playbackID, .init($0)) }))
    var rng = SplitMix64(seed: seed)
    return ranker.rank(
      library: songs, index: index, affinity: affinity, journal: journal, pendingPlays: [:],
      ratings: ratings, starred: [], likedAlbums: likedAlbums, likedArtists: likedArtists,
      mode: .playSomething, count: count, now: now, rng: &rng)
  }

  /// Explore picks per artist over many seeds, for two artists the listener
  /// plays equally.
  private func explorePicks(
    _ songs: [Song], journal: JournalSnapshot = JournalSnapshot()
  ) -> [String: Int] {
    var affinity = AffinitySnapshot()
    affinity.aggregates[.artist] = [
      "ar-A": .init(weight: 10, lastPlayAt: nil, plays: 10),
      "ar-B": .init(weight: 10, lastPlayAt: nil, plays: 10),
    ]
    var picks: [String: Int] = [:]
    for seed in 1...1000 {
      for pick in rank(songs, affinity: affinity, journal: journal, count: 6, seed: UInt64(seed))
        .record.picks where pick.slot == "explore"
      {
        picks[pick.artist, default: 0] += 1
      }
    }
    return picks
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

  func testARatingShowsWhoseItIs() throws {
    let id = library()[0].playbackID
    let own = try XCTUnwrap(pick(ratings: [id: .init(stars: 5, source: .song)]))
    let album = try XCTUnwrap(pick(ratings: [id: .init(stars: 5, source: .album)]))
    let artist = try XCTUnwrap(pick(ratings: [id: .init(stars: 5, source: .artist)]))
    XCTAssertTrue(own.scores.contains("rating=5+.35"), own.scores)
    XCTAssertTrue(album.scores.contains("rating=5(album)+.35"), album.scores)
    XCTAssertTrue(artist.scores.contains("rating=5(artist)+.35"), artist.scores)
    XCTAssertTrue(own.reason.hasPrefix("boosted"), own.reason)
    XCTAssertTrue(album.reason.hasPrefix("album boosted"), album.reason)
    XCTAssertTrue(artist.reason.hasPrefix("artist boosted"), artist.reason)
  }

  /// An avoided artist's songs stay out unless their own rating says otherwise
  /// (SmartPlaybackService.effectiveRatings gives the song's rating first).
  func testAnAvoidedArtistIsExcludedUnlessTheSongIsRated() {
    let id = library()[0].playbackID
    XCTAssertNil(pick(ratings: [id: .init(stars: 1, source: .artist)]))
    XCTAssertNil(pick(ratings: [id: .init(stars: 1, source: .album)]))
    XCTAssertNotNil(pick(ratings: [id: .init(stars: 3, source: .song)]))
  }

  func testLikedAlbumsAndArtistsAddACappedBonus() throws {
    let song = library()[0]
    let none = try XCTUnwrap(pick())
    let album = try XCTUnwrap(pick(likedAlbums: [song.albumId]))
    let artist = try XCTUnwrap(pick(likedArtists: ["ar0"]))
    let both = try XCTUnwrap(pick(likedAlbums: [song.albumId], likedArtists: ["ar0"]))
    XCTAssertTrue(none.scores.contains("coll=.00"), none.scores)
    XCTAssertTrue(album.scores.contains("coll=.10"), album.scores)
    XCTAssertTrue(artist.scores.contains("coll=.08"), artist.scores)
    XCTAssertTrue(both.scores.contains("coll=.15"), both.scores)
    XCTAssertTrue(album.reason.contains("liked album"), album.reason)
    XCTAssertTrue(artist.reason.contains("liked artist"), artist.reason)
  }

  /// A liked artist's and a liked album's unplayed songs are explored like a
  /// frequent artist's.
  func testLikedCollectionsAreExplored() {
    let songs = (0..<6).map { song("a\($0)", artist: "A", album: "al-A\($0 % 2)") }
    let notes = { (record: MixRecord) in record.notes.joined(separator: "; ") }
    XCTAssertTrue(notes(rank(songs, count: 6, seed: 1).record).contains("explore pool: 0 songs"))
    XCTAssertTrue(
      notes(rank(songs, likedArtists: ["ar-A"], count: 6, seed: 1).record)
        .contains("explore pool: 6 songs by 1 artists"))
    XCTAssertTrue(
      notes(rank(songs, likedAlbums: ["al-A0"], count: 6, seed: 1).record)
        .contains("explore pool: 3 songs by 1 artists"))
  }

  /// Ten played favourites against four hundred unplayed songs: the sampling
  /// exponent lets the favourites fill most of the mix, where weighing them
  /// linearly leaves them under half.
  func testFavouritesWinOverHundredsOfWeakSongs() {
    let favourites = (0..<10).map { song("f\($0)", artist: "F\($0)", album: "al-F\($0)", plays: 5) }
    let weak = (0..<400).map { song("w\($0)", artist: "W\($0 / 2)", album: "al-W\($0)") }
    var affinity = AffinitySnapshot()
    affinity.aggregates[.song] = Dictionary(
      uniqueKeysWithValues: favourites.map {
        ($0.playbackID, AffinitySnapshot.Aggregate(weight: 8, lastPlayAt: nil, plays: 5))
      })
    let ids = Set(favourites.map(\.id))
    func favouritesPicked(_ ranker: MixRanker) -> Double {
      let total = (1...50).reduce(0) { sum, seed in
        let mix = rank(
          favourites + weak, ranker: ranker, affinity: affinity, count: 10, seed: UInt64(seed))
        return sum + mix.songs.filter { ids.contains($0.id) }.count
      }
      return Double(total) / 50
    }
    let linear = MixRanker(config: .init(preferredSamplingExponent: 1))
    let squared = favouritesPicked(MixRanker())
    let flat = favouritesPicked(linear)
    XCTAssertGreaterThanOrEqual(squared, 6, "\(squared)")
    XCTAssertGreaterThan(squared, flat + 1.5, "\(squared) vs \(flat)")
  }

  /// Explore picks an artist by the mean weight of its songs, so a large
  /// catalogue does not outweigh a small one.
  func testExploreTreatsCatalogueSizesAlike() throws {
    let songs =
      (0..<20).map { song("a\($0)", artist: "A", album: "al-A\($0)") }
      + (0..<2).map { song("b\($0)", artist: "B", album: "al-B\($0)") }
    let picks = explorePicks(songs)
    let a = Double(picks["A"] ?? 0)
    let b = Double(picks["B"] ?? 0)
    XCTAssertGreaterThan(a + b, 100)
    XCTAssertEqual(b / (a + b), 0.5, accuracy: 0.12, "\(picks)")
  }

  /// Without any history every artist is equally likely, whatever its size.
  func testBootstrapTreatsCatalogueSizesAlike() {
    let songs =
      (0..<20).map { song("a\($0)", artist: "A", album: "al-A\($0)") }
      + (0..<2).map { song("b\($0)", artist: "B", album: "al-B\($0)") }
    var firsts: [String: Int] = [:]
    for seed in 1...1000 {
      let record = rank(songs, count: 1, seed: UInt64(seed)).record
      XCTAssertTrue(record.notes.contains("bootstrap"))
      if let artist = record.picks.first?.artist { firsts[artist, default: 0] += 1 }
    }
    let b = Double(firsts["B"] ?? 0)
    XCTAssertEqual(b / Double(firsts.values.reduce(0, +)), 0.5, accuracy: 0.08, "\(firsts)")
  }

  func testSkipsLowerExplorePicks() throws {
    let songs =
      (0..<3).map { song("a\($0)", artist: "A", album: "al-A\($0)") }
      + (0..<3).map { song("b\($0)", artist: "B", album: "al-B\($0)") }
    var journal = JournalSnapshot()
    for n in 0..<3 {
      journal.skips["a\(n)"] = [.init(at: now, weight: 1, artistKey: "ar-A")]
    }
    let fresh = explorePicks(songs)
    let skipped = explorePicks(songs, journal: journal)
    XCTAssertEqual(
      Double(fresh["A"] ?? 0), Double(fresh["B"] ?? 0), accuracy: Double(fresh["B"] ?? 0) * 0.25,
      "\(fresh)")
    XCTAssertLessThan(Double(skipped["A"] ?? 0), Double(skipped["B"] ?? 0) * 0.7, "\(skipped)")

    var affinity = AffinitySnapshot()
    affinity.aggregates[.artist] = ["ar-A": .init(weight: 10, lastPlayAt: nil, plays: 10)]
    let line = try XCTUnwrap(
      rank(Array(songs.prefix(3)), affinity: affinity, journal: journal, count: 6, seed: 1)
        .record.picks.first { $0.slot == "explore" }?.scores)
    XCTAssertTrue(line.contains("skip=-.15 press="), line)
  }

  /// A library smaller than the mix gives all of it, the caps relaxed.
  func testATinyLibraryFillsWhatItCan() {
    let songs = (0..<3).map { song("t\($0)", artist: "T", album: "al-T") }
    let picked = rank(songs, count: 15, seed: 1).songs
    XCTAssertEqual(Set(picked.map(\.id)), ["t0", "t1", "t2"])
    XCTAssertEqual(picked.count, 3)
  }
}
