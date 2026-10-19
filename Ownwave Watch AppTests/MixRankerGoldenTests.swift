import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

/// Whole mixes recorded from the ranker for fixed inputs and seeds: the songs
/// in order and every field of the record. A change to any formula, constant
/// or draw order of the ranker shows up here; record the new values only
/// when that change is meant.
final class MixRankerGoldenTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

  /// Eight artists with six songs each over two albums and three genres, a
  /// title sibling of a song heard an hour ago, a song without an artist id
  /// and one played by its media file id.
  private func library(playCounts: Bool = true) -> [Song] {
    let genres = ["Rock", "Jazz", "Pop"]
    var songs = (0..<8).flatMap { artist in
      (0..<6).map { track in
        var song = Song.fixture(
          "s\(artist)-\(track)", artist: "Artist \(artist)", album: "al\(artist)-\(track % 2)",
          albumName: "Album \(artist)-\(track % 2)")
        song.artistId = "ar\(artist)"
        song.genre = genres[artist % 3]
        if track == 5 { song.genres = [genres[artist % 3], "Live"] }
        song.year = 1975 + artist * 5
        song.playCount = playCounts ? (artist * 5 + track * 3) % 13 : nil
        return song
      }
    }
    let siblings = zip(["x-intro", "x-live"], ["Intro", "Intro (Live)"]).enumerated().map {
      var song = Song.fixture($1.0, title: $1.1, artist: "Artist 1", album: "al1-\($0)")
      song.artistId = "ar1"
      song.genre = "Jazz"
      song.playCount = playCounts ? 3 : nil
      return song
    }
    var guest = Song.fixture("x-guest", artist: "Guest Band", album: "al-guest")
    guest.genre = "Rock"
    var media = Song.fixture("x-media", artist: "Artist 3", album: "al3-0", mediaFileId: "mf-media")
    media.artistId = "ar3"
    media.genre = "Rock"
    media.playCount = playCounts ? 1 : nil
    songs += siblings + [guest, media]
    return songs
  }

  /// Every song but the guest's, whose entry the ranker builds itself;
  /// Artist 7 goes by its name key.
  private func index(_ songs: [Song]) -> SmartPlaybackService.LibraryIndex {
    let keys = ["ar7": "name:artist7"]
    return SmartPlaybackService.LibraryIndex(
      songs: Dictionary(
        uniqueKeysWithValues: songs.filter { $0.id != "x-guest" }.map {
          ($0.playbackID, .init($0, artistKeys: keys))
        }))
  }

  private func history(bootstrapComplete: Bool) -> AffinitySnapshot {
    var affinity = AffinitySnapshot()
    var songs: [String: AffinitySnapshot.Aggregate] = [:]
    for artist in 0..<4 {
      for track in 0..<3 {
        songs["s\(artist)-\(track)"] = .init(
          weight: Double(artist + 1) * 1.5 + Double(track),
          lastPlayAt: hoursAgo(Double(artist * 7 + track) * 5), plays: artist + track + 1)
      }
    }
    songs["x-intro"] = .init(weight: 2, lastPlayAt: hoursAgo(30), plays: 3)
    affinity.aggregates[.song] = songs
    affinity.aggregates[.artist] = [
      "ar0": .init(weight: 12, lastPlayAt: hoursAgo(2), plays: 14),
      "ar1": .init(weight: 6, lastPlayAt: hoursAgo(9), plays: 7),
      "ar2": .init(weight: 3, lastPlayAt: hoursAgo(40), plays: 4),
      "ar3": .init(weight: 1.5, lastPlayAt: nil, plays: 2),
      "ar7": .init(weight: 4, lastPlayAt: hoursAgo(100), plays: 5),
    ]
    affinity.aggregates[.album] = [
      "al0-0": .init(weight: 8, lastPlayAt: nil, plays: 9),
      "al1-1": .init(weight: 3, lastPlayAt: nil, plays: 3),
    ]
    affinity.aggregates[.genre] = [
      "Rock": .init(weight: 20, lastPlayAt: nil, plays: 22),
      "Jazz": .init(weight: 9, lastPlayAt: nil, plays: 10),
    ]
    affinity.aggregates[.era] = ["1970s": .init(weight: 10, lastPlayAt: nil, plays: 11)]
    affinity.state.bootstrapComplete = bootstrapComplete
    return affinity
  }

  /// Skips on three songs of Artist 4 and on Artist 5's songs, two of them
  /// no longer in the library, and recent listens.
  private func journal() -> JournalSnapshot {
    var journal = JournalSnapshot()
    journal.lastHeardAt = ["x-intro": hoursAgo(1), "s2-1": hoursAgo(0.5), "s5-4": hoursAgo(20)]
    let artist4 = "name:artist4"
    let artist5 = "name:artist5"
    journal.skips = [
      "s4-0": [.init(at: hoursAgo(3), weight: 1, artistKey: artist4)],
      "s4-1": [
        .init(at: hoursAgo(50), weight: 0.5, artistKey: artist4),
        .init(at: hoursAgo(200), weight: 1, artistKey: artist4),
      ],
      "s4-2": [.init(at: hoursAgo(10), weight: 1, artistKey: artist4)],
      "s5-0": [.init(at: hoursAgo(5), weight: 1, artistKey: artist5)],
      "gone-1": [.init(at: hoursAgo(6), weight: 1, artistKey: artist5)],
      "gone-2": [.init(at: hoursAgo(80), weight: 0.5, artistKey: artist5)],
    ]
    return journal
  }

  private let ratings: [String: MixRanker.Rating] = [
    "s0-3": .init(stars: 5, source: .song),
    "s1-4": .init(stars: 4, source: .album),
    "s2-2": .init(stars: 2, source: .song),
    "s6-0": .init(stars: 1, source: .song),
    "s6-1": .init(stars: 5, source: .artist),
    "s7-5": .init(stars: 3, source: .song),
  ]

  private func keepPlaying(minutes: Double, genres: Set<String>) -> SmartPlaybackService.MixMode {
    .keepPlaying(
      .init(
        seed: .init(artist: "Artist 2", albumId: "al2-0"), anchorGenres: genres,
        sessionMinutes: minutes, queueIds: ["s2-3", "x-media"]))
  }

  private func rank(
    _ songs: [Song], affinity: AffinitySnapshot = AffinitySnapshot(),
    journal: JournalSnapshot = JournalSnapshot(), pendingPlays: [String: Date] = [:],
    recentPlays: [String: Int] = [:], ratings: [String: MixRanker.Rating] = [:],
    starred: Set<String> = [], likedAlbums: Set<String> = [], likedArtists: Set<String> = [],
    mode: SmartPlaybackService.MixMode = .playSomething, count: Int, seed: UInt64
  ) -> [String] {
    var rng = SplitMix64(seed: seed)
    let (songs, record) = MixRanker().rank(
      library: songs, index: index(songs), affinity: affinity, journal: journal,
      pendingPlays: pendingPlays, recentPlays: recentPlays, ratings: ratings, starred: starred,
      likedAlbums: likedAlbums, likedArtists: likedArtists, mode: mode, count: count, now: now,
      rng: &rng)
    return [
      "songs: " + songs.map(\.id).joined(separator: " "),
      "\(record.mode) at=\(record.at.timeIntervalSince1970) eligible=\(record.eligible) "
        + "explore=\(record.exploreShare)",
    ] + record.notes.map { "note: " + $0 }
      + record.picks.map {
        "\($0.slot) \($0.songId) \($0.title) / \($0.artist) | \($0.why.kind.rawValue): "
          + "\($0.why.note) | \($0.reason) | \($0.scores)"
      }
  }

  /// `bootstrapComplete` false trusts the log only half.
  private func richMix(
    mode: SmartPlaybackService.MixMode, bootstrapComplete: Bool = true, count: Int, seed: UInt64
  ) -> [String] {
    rank(
      library(), affinity: history(bootstrapComplete: bootstrapComplete),
      journal: journal(), pendingPlays: ["s3-2": hoursAgo(2)],
      recentPlays: ["s0-0": 4, "s0-1": 2, "s1-0": 6, "s3-1": 3, "gone-1": 9], ratings: ratings,
      starred: ["s3-4", "s5-5"], likedAlbums: ["al2-1"], likedArtists: ["ar6"], mode: mode,
      count: count, seed: seed)
  }

  private func assertLines(
    _ actual: [String], _ expected: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let expected = expected.components(separatedBy: "\n")
    for (n, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
      XCTFail("line \(n + 1)\n  got:  \(pair.0)\n  want: \(pair.1)", file: file, line: line)
    }
    XCTAssertEqual(actual.count, expected.count, "line count", file: file, line: line)
  }

  func testPlaySomethingWithHistory() {
    assertLines(
      richMix(mode: .playSomething, bootstrapComplete: false, count: 12, seed: 11),
      Golden.playSomething)
  }

  func testKeepPlayingWithHistory() {
    assertLines(
      richMix(mode: keepPlaying(minutes: 45, genres: ["Jazz"]), count: 12, seed: 12),
      Golden.keepPlaying)
  }

  func testKeepPlayingBoundByItsGenres() {
    assertLines(
      richMix(mode: keepPlaying(minutes: 200, genres: ["Jazz"]), count: 4, seed: 13),
      Golden.keepPlayingBound)
  }

  func testColdStartOnRatingsAndStars() {
    assertLines(
      rank(
        library(), ratings: ratings, starred: ["s3-4"], likedAlbums: ["al2-1"], count: 10,
        seed: 14),
      Golden.coldStartOnRatings)
  }

  func testColdStartWidensToGenres() {
    assertLines(rank(library(), starred: ["s3-4"], count: 6, seed: 15), Golden.coldStartToGenres)
  }

  func testColdStartOnServerCountsWidensToTheLibrary() {
    assertLines(
      rank(library(), journal: journal(), count: 20, seed: 15), Golden.coldStartToLibrary)
  }

  func testBootstrap() {
    assertLines(rank(library(playCounts: false), count: 6, seed: 16), Golden.bootstrap)
  }

  /// Two liked artists and their every song in the mix: exploration needs its
  /// second round and the caps give way.
  func testSmallLibraryRelaxesTheCaps() {
    let songs = library().filter { $0.artistId == "ar0" || $0.artistId == "ar1" }
    assertLines(
      rank(
        songs, affinity: history(bootstrapComplete: true), journal: journal(),
        pendingPlays: ["s0-4": hoursAgo(3), "s1-3": hoursAgo(50)], likedArtists: ["ar0", "ar1"],
        mode: keepPlaying(minutes: 120, genres: []), count: 14, seed: 17),
      Golden.smallLibrary)
  }

  /// One genre and a pick from another: the genre ceiling gives way before
  /// the caps.
  func testGenreCeilingGivesWayFirst() {
    let songs = library().filter { $0.genre == "Rock" || $0.id == "s1-0" }
    assertLines(
      rank(songs, affinity: history(bootstrapComplete: true), count: 6, seed: 18),
      Golden.genreCeiling)
  }

  /// Fifteen songs of one genre fill the pool of a mix of three; with the
  /// genre ceiling reached, the rest by weight fills it.
  func testTheRestFollowsThePool() {
    let rock = (0..<20).map {
      var song = Song.fixture("r\($0)", artist: "R\($0 / 4)", album: "al-r\($0)")
      song.artistId = "ar-r\($0 / 4)"
      song.genre = "Rock"
      return song
    }
    let jazz = (0..<2).map {
      var song = Song.fixture("j\($0)", artist: "J", album: "al-j\($0)")
      song.artistId = "ar-j"
      song.genre = "Jazz"
      return song
    }
    var affinity = AffinitySnapshot()
    affinity.aggregates[.song] = Dictionary(
      uniqueKeysWithValues: rock.map { ($0.id, .init(weight: 2, lastPlayAt: nil, plays: 2)) })
    affinity.state.bootstrapComplete = true
    assertLines(rank(rock + jazz, affinity: affinity, count: 3, seed: 19), Golden.restAfterPool)
  }
}

/// The mixes as the ranker gave them when they were recorded.
private enum Golden {
  static let playSomething = """
    songs: s3-1 s6-1 s2-5 s6-4 s4-3 x-media s7-5 s0-3 s7-4 s1-2 s5-1 s1-0
    playSomething at=1790000000.0 eligible=51 explore=0.16666666666666666
    note: explore pool: 21 songs by 7 artists, quota 2, taken 2
    preferred s3-1 Song s3-1 / Artist 3 | history: Played 3 times in 60 days | favourite, high artist affinity | src=sampled artist=.14 album=.05 genre=.14 era=.02 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.51
    preferred s6-1 Song s6-1 / Artist 6 | rated: From an artist you rated 5 | artist boosted, liked artist, favourite genre | src=sampled artist=.11 album=.05 genre=.14 era=.02 song=.08 star=.00 coll=.08 rating=5(artist)+.35 skip=-.00 press=-.00 cool=1.00 final=.84
    preferred s2-5 Song s2-5 / Artist 2 | liked: From Album 2-1, an album you liked | liked album, favourite, high artist affinity | src=sampled artist=.16 album=.05 genre=.08 era=.02 song=.08 star=.00 coll=.10 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.51
    preferred s6-4 Song s6-4 / Artist 6 | liked: From an artist you liked | liked artist, favourite genre | src=sampled artist=.11 album=.05 genre=.14 era=.02 song=.05 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.46
    preferred s4-3 Song s4-3 / Artist 4 | history: Fits what you play | favourite genre | src=sampled artist=.12 album=.05 genre=.12 era=.02 song=.05 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 cool=1.00 final=.36
    explore mf-media Song x-media / Artist 3 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.59 genre=.85 plays=1 rating=0 skip=-.00 press=-.00 cool=1.00 final=1.19
    preferred s7-5 Song s7-5 / Artist 7 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.17 album=.05 genre=.12 era=.02 song=.08 star=.00 coll=.00 rating=3+.00 skip=-.00 press=-.00 cool=1.00 final=.46
    preferred s0-3 Song s0-3 / Artist 0 | rated: You rated this 5 | boosted, favourite, high artist affinity | src=sampled artist=.19 album=.05 genre=.14 era=.02 song=.08 star=.00 coll=.00 rating=5+.35 skip=-.00 press=-.00 cool=1.00 final=.85
    preferred s7-4 Song s7-4 / Artist 7 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.17 album=.05 genre=.12 era=.02 song=.08 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.46
    preferred s1-2 Song s1-2 / Artist 1 | history: You play Artist 1 often · 6 plays in 60 days | favourite, high artist affinity | src=sampled artist=.18 album=.05 genre=.12 era=.02 song=.15 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.54
    explore s5-1 Song s5-1 / Artist 5 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.49 genre=.49 plays=2 rating=0 skip=-.00 press=-.02 cool=1.00 final=.70
    preferred s1-0 Song s1-0 / Artist 1 | history: Played 6 times in 60 days | favourite, high artist affinity | src=sampled artist=.18 album=.05 genre=.12 era=.02 song=.12 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.51
    """

  static let keepPlaying = """
    songs: s0-3 s2-5 s0-5 s6-1 s1-4 s4-4 s1-3 s2-4 s5-2 s7-1 s3-0 s3-4
    keepPlaying at=1790000000.0 eligible=49 explore=0.3333333333333333
    note: anchor genres: Jazz (20 songs by 3 artists, not bounding)
    note: explore pool: 19 songs by 7 artists, quota 4, taken 4
    preferred s0-3 Song s0-3 / Artist 0 | rated: You rated this 5 | boosted, high artist affinity | src=sampled artist=.17 album=.00 genre=.11 era=.02 song=.00 star=.00 coll=.00 rating=5+.35 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.67
    preferred s2-5 Song s2-5 / Artist 2 | liked: From Album 2-1, an album you liked | liked album, same artist as before | src=sampled artist=.09 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.10 rating=0+.00 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=.36
    explore s0-5 Song s0-5 / Artist 0 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.69 genre=.69 plays=2 rating=0 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.94
    preferred s6-1 Song s6-1 / Artist 6 | rated: From an artist you rated 5 | artist boosted, liked artist, favourite genre | src=sampled artist=.00 album=.00 genre=.11 era=.00 song=.00 star=.00 coll=.08 rating=5(artist)+.35 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.56
    preferred s1-4 Song s1-4 / Artist 1 | rated: From Album 1-0, an album you rated 4 | album rated 4, fits the session's genres, high artist affinity | src=sampled artist=.13 album=.00 genre=.08 era=.00 song=.00 star=.00 coll=.00 rating=4(album)+.20 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=.58
    preferred s4-4 Song s4-4 / Artist 4 | history: Fits this listening session | fits the session's genres, favourite genre | src=sampled artist=.00 album=.00 genre=.08 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 ctx=.15 cool=1.00 final=.24
    explore s1-3 Song s1-3 / Artist 1 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.52 genre=.52 plays=1 rating=0 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=1.02
    preferred s2-4 Song s2-4 / Artist 2 | history: Same artist as a song you just heard | same artist as before | src=sampled artist=.09 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 ctx=.03 cool=1.00 final=.14
    explore s5-2 Song s5-2 / Artist 5 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.00 genre=.00 plays=5 rating=0 skip=-.00 press=-.02 ctx=.00 cool=1.00 final=.10
    preferred s7-1 Song s7-1 / Artist 7 | history: Fits this listening session | fits the session's genres, favourite genre | src=sampled artist=.10 album=.00 genre=.08 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=.36
    preferred s3-0 Song s3-0 / Artist 3 | history: Fits what you play | favourite, favourite genre | src=sampled artist=.06 album=.00 genre=.11 era=.00 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.33
    explore s3-4 Song s3-4 / Artist 3 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.25 genre=.69 plays=1 rating=0 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.84
    """

  static let keepPlayingBound = """
    songs: s4-4 s1-3 s7-2 s1-2
    keepPlaying at=1790000000.0 eligible=20 explore=0.5
    note: anchor genres: Jazz
    note: explore pool: 7 songs by 2 artists, quota 2, taken 2
    preferred s4-4 Song s4-4 / Artist 4 | history: Fits this listening session | fits the session's genres, favourite genre | src=sampled artist=.00 album=.00 genre=.08 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 ctx=.15 cool=1.00 final=.24
    explore s1-3 Song s1-3 / Artist 1 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.52 genre=.52 plays=1 rating=0 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=1.02
    explore s7-2 Song s7-2 / Artist 7 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.43 genre=.52 plays=2 rating=0 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=.78
    preferred s1-2 Song s1-2 / Artist 1 | history: You play Artist 1 often · 6 plays in 60 days | favourite, fits the session's genres, high artist affinity | src=sampled artist=.13 album=.00 genre=.08 era=.00 song=.13 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 ctx=.15 cool=1.00 final=.51
    """

  static let coldStartOnRatings = """
    songs: s6-1 s1-2 s6-2 s3-2 s0-1 s2-5 s3-1 s0-4 s2-3 x-intro
    playSomething at=1790000000.0 eligible=32 explore=0.2
    note: cold start: ratings/stars, their artists
    note: explore pool: 14 songs by 5 artists, quota 2, taken 2
    preferred s6-1 Song s6-1 / Artist 6 | rated: From an artist you rated 5 | artist boosted, favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.04 song=.15 star=.00 coll=.00 rating=5(artist)+.35 skip=-.00 press=-.00 cool=1.00 final=1.03
    preferred s1-2 Song s1-2 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.72
    preferred s6-2 Song s6-2 / Artist 6 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.70
    preferred s3-2 Song s3-2 / Artist 3 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.09 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    explore s0-1 Song s0-1 / Artist 0 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.92 genre=1.00 plays=3 rating=0 skip=-.00 press=-.00 cool=1.00 final=1.09
    preferred s2-5 Song s2-5 / Artist 2 | liked: From Album 2-1, an album you liked | liked album, favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.10 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.81
    preferred s3-1 Song s3-1 / Artist 3 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.13 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.67
    preferred s0-4 Song s0-4 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    preferred s2-3 Song s2-3 / Artist 2 | liked: From Album 2-1, an album you liked | liked album, favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.14 star=.00 coll=.10 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.79
    explore x-intro Intro / Artist 1 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=1.00 genre=1.00 plays=3 rating=0 skip=-.00 press=-.00 cool=1.00 final=1.12
    """

  static let coldStartToGenres = """
    songs: s3-3 s6-5 s0-2 s6-2 s0-1 x-media
    playSomething at=1790000000.0 eligible=20 explore=0.16666666666666666
    note: cold start: ratings/stars, their genres
    note: explore pool: 3 songs by 1 artists, quota 1, taken 1
    note: caps relaxed
    preferred s3-3 Song s3-3 / Artist 3 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.70
    preferred s6-5 Song s6-5 / Artist 6 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.04 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.67
    preferred s0-2 Song s0-2 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.67
    preferred s6-2 Song s6-2 / Artist 6 | history: Fits what you play | favourite, high artist affinity | src=relaxed genre artist=.22 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.70
    preferred s0-1 Song s0-1 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=relaxed genre artist=.22 album=.10 genre=.16 era=.03 song=.10 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.63
    explore mf-media Song x-media / Artist 3 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.93 genre=1.00 plays=1 rating=0 skip=-.00 press=-.00 cool=1.00 final=1.54
    """

  static let coldStartToLibrary = """
    songs: s0-2 s1-2 s0-3 s7-1 s1-5 s3-3 s6-2 s5-2 s4-4 s6-5 s3-2 s4-5 s2-0 s7-5 s2-4 s5-3 x-guest s1-0 s0-4 s1-1
    playSomething at=1790000000.0 eligible=52 explore=0.0
    note: cold start: server counts, their library
    note: explore pool: 0 songs by 0 artists, quota 3, taken 0
    note: caps relaxed
    preferred s0-2 Song s0-2 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.67
    preferred s1-2 Song s1-2 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.72
    preferred s0-3 Song s0-3 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    preferred s7-1 Song s7-1 / Artist 7 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.71
    preferred s1-5 Song s1-5 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.15 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.71
    preferred s3-3 Song s3-3 / Artist 3 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.70
    preferred s6-2 Song s6-2 / Artist 6 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.70
    preferred s5-2 Song s5-2 / Artist 5 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.23 album=.10 genre=.16 era=.04 song=.13 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 cool=1.00 final=.66
    preferred s4-4 Song s4-4 / Artist 4 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.23 album=.10 genre=.16 era=.03 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 cool=1.00 final=.66
    preferred s6-5 Song s6-5 / Artist 6 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.10 genre=.16 era=.04 song=.14 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.67
    preferred s3-2 Song s3-2 / Artist 3 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.22 album=.09 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    preferred s4-5 Song s4-5 / Artist 4 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.23 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 cool=1.00 final=.69
    preferred s2-0 Song s2-0 / Artist 2 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.71
    preferred s7-5 Song s7-5 / Artist 7 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.71
    preferred s2-4 Song s2-4 / Artist 2 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.71
    preferred s5-3 Song s5-3 / Artist 5 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.23 album=.09 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.02 cool=1.00 final=.68
    preferred x-guest Song x-guest / Guest Band | history: Fits what you play | favourite genre | src=sampled artist=.00 album=.00 genre=.16 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.18
    preferred s1-0 Song s1-0 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=relaxed caps artist=.24 album=.10 genre=.16 era=.04 song=.13 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    preferred s0-4 Song s0-4 / Artist 0 | history: Fits what you play | favourite, high artist affinity | src=relaxed caps artist=.22 album=.10 genre=.16 era=.03 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.69
    preferred s1-1 Song s1-1 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=relaxed caps artist=.24 album=.10 genre=.16 era=.04 song=.16 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.72
    """

  static let bootstrap = """
    songs: s5-1 x-guest s7-0 s4-0 s0-1 s5-0
    playSomething at=1790000000.0 eligible=52 explore=0.0
    note: bootstrap
    note: explore pool: 0 songs by 0 artists, quota 1, taken 0
    preferred s5-1 Song s5-1 / Artist 5 | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.00
    preferred x-guest Song x-guest / Guest Band | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.02
    preferred s7-0 Song s7-0 / Artist 7 | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.00
    preferred s4-0 Song s4-0 / Artist 4 | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.00
    preferred s0-1 Song s0-1 / Artist 0 | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.00
    preferred s5-0 Song s5-0 / Artist 5 | history: Fits what you play | bootstrap | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.00
    """

  static let smallLibrary = """
    songs: s0-2 s1-2 s0-3 s1-3 s0-1 s1-5 s0-4 s1-0 s0-0 x-live s0-5 s1-4 s1-1
    keepPlaying at=1790000000.0 eligible=14 explore=0.3076923076923077
    note: explore pool: 7 songs by 2 artists, quota 6, taken 4
    note: caps relaxed
    preferred s0-2 Song s0-2 / Artist 0 | liked: From an artist you liked | liked artist, favourite, high artist affinity | src=relaxed caps artist=.17 album=.08 genre=.11 era=.02 song=.11 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=.82 final=.48
    preferred s1-2 Song s1-2 / Artist 1 | liked: From an artist you liked | liked artist, favourite, high artist affinity | src=relaxed caps artist=.13 album=.00 genre=.08 era=.00 song=.13 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.44
    preferred s0-3 Song s0-3 / Artist 0 | liked: From an artist you liked | liked artist, high artist affinity | src=relaxed caps artist=.17 album=.00 genre=.11 era=.02 song=.00 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.40
    explore s1-3 Song s1-3 / Artist 1 | explore: Explore pick · not heard in 2 days | less-played track by a frequent artist | src=explore artist=.52 genre=.52 plays=1 rating=0 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.92
    explore s0-1 Song s0-1 / Artist 0 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.69 genre=.69 plays=3 rating=0 skip=-.00 press=-.00 ctx=.00 cool=.59 final=.48
    preferred s1-5 Song s1-5 / Artist 1 | liked: From an artist you liked | liked artist, high artist affinity | src=relaxed caps artist=.13 album=.05 genre=.08 era=.00 song=.00 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.36
    preferred s0-4 Song s0-4 / Artist 0 | liked: From an artist you liked | liked artist, high artist affinity | src=relaxed caps artist=.17 album=.08 genre=.11 era=.02 song=.00 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=.42 final=.20
    preferred s1-0 Song s1-0 / Artist 1 | liked: From an artist you liked | liked artist, favourite, high artist affinity | src=relaxed caps artist=.13 album=.00 genre=.08 era=.00 song=.10 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.41
    preferred s0-0 Song s0-0 / Artist 0 | liked: From an artist you liked | liked artist, high artist affinity | src=relaxed caps artist=.17 album=.08 genre=.11 era=.02 song=.07 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=.05 final=.03
    preferred x-live Intro (Live) / Artist 1 | liked: From an artist you liked | liked artist, high artist affinity | src=relaxed caps artist=.13 album=.05 genre=.08 era=.00 song=.00 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=.45 final=.16
    explore s0-5 Song s0-5 / Artist 0 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.69 genre=.69 plays=2 rating=0 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.94
    explore s1-4 Song s1-4 / Artist 1 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.52 genre=.52 plays=4 rating=0 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.58
    preferred s1-1 Song s1-1 / Artist 1 | liked: From an artist you liked | liked artist, favourite, high artist affinity | src=relaxed caps artist=.13 album=.05 genre=.08 era=.00 song=.12 star=.00 coll=.08 rating=0+.00 skip=-.00 press=-.00 ctx=.00 cool=1.00 final=.48
    """

  static let genreCeiling = """
    songs: s0-4 s1-0 s3-1 s6-2 s3-3 s0-5
    playSomething at=1790000000.0 eligible=21 explore=0.16666666666666666
    note: explore pool: 3 songs by 1 artists, quota 1, taken 1
    note: caps relaxed
    preferred s0-4 Song s0-4 / Artist 0 | history: Fits what you play | high artist affinity | src=sampled artist=.17 album=.08 genre=.11 era=.02 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.40
    preferred s1-0 Song s1-0 / Artist 1 | history: Fits what you play | favourite, high artist affinity | src=sampled artist=.13 album=.00 genre=.08 era=.00 song=.10 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.33
    preferred s3-1 Song s3-1 / Artist 3 | history: Fits what you play | favourite, favourite genre | src=sampled artist=.06 album=.00 genre=.11 era=.00 song=.15 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.34
    preferred s6-2 Song s6-2 / Artist 6 | history: Fits what you play | favourite genre | src=relaxed genre artist=.00 album=.00 genre=.11 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.13
    preferred s3-3 Song s3-3 / Artist 3 | history: Fits what you play | favourite genre | src=sampled artist=.06 album=.00 genre=.11 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.19
    explore s0-5 Song s0-5 / Artist 0 | explore: Explore pick · rarely played | less-played track by a frequent artist | src=explore artist=.69 genre=.69 plays=2 rating=0 skip=-.00 press=-.00 cool=1.00 final=.94
    """

  static let restAfterPool = """
    songs: r7 r11 j0
    playSomething at=1790000000.0 eligible=22 explore=0.0
    note: explore pool: 0 songs by 0 artists, quota 1, taken 0
    preferred r7 Song r7 / R1 | history: Fits what you play | favourite | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.08 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.10
    preferred r11 Song r11 / R2 | history: Fits what you play | favourite | src=sampled artist=.00 album=.00 genre=.00 era=.00 song=.08 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.10
    preferred j0 Song j0 / J | history: Fits what you play | steady pick | src=remainder artist=.00 album=.00 genre=.00 era=.00 song=.00 star=.00 coll=.00 rating=0+.00 skip=-.00 press=-.00 cool=1.00 final=.02
    """
}
