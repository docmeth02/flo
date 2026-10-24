import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class TasteTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func song(_ id: String, artistId: String, artist: String, album: String) -> Song {
    var song = Song.fixture(id, artist: artist, album: album, albumName: "Album \(album)")
    song.artistId = artistId
    return song
  }

  private func note(_ facts: MixReason.Facts) -> String {
    MixReason.make(facts).note
  }

  /// An explore slot says so first; then ratings, likes and plays, in that order.
  func testReasonsFollowTheirOrder() {
    var facts = MixReason.Facts(artist: "BABYMETAL", album: "Budokan", now: now)
    XCTAssertEqual(note(facts), "Fits what you play")
    facts.anchored = true
    XCTAssertEqual(note(facts), "Fits this listening session")
    facts.seedArtist = true
    XCTAssertEqual(note(facts), "Same artist as a song you just heard")
    facts.artistPlays = 31
    XCTAssertEqual(note(facts), "You play BABYMETAL often · 31 plays in 60 days")
    facts.songPlays = 9
    XCTAssertEqual(note(facts), "Played 9 times in 60 days")
    facts.topArtist = true
    XCTAssertEqual(note(facts), "BABYMETAL is your most-played artist")
    XCTAssertEqual(MixReason.make(facts).kind, .history)

    facts.likedArtist = true
    XCTAssertEqual(note(facts), "From an artist you liked")
    facts.likedAlbum = true
    XCTAssertEqual(note(facts), "From Budokan, an album you liked")
    facts.starred = true
    XCTAssertEqual(note(facts), "You liked this song")
    XCTAssertEqual(MixReason.make(facts).kind, .liked)

    facts.rating = 3
    XCTAssertEqual(MixReason.make(facts).kind, .liked)
    facts.rating = 5
    facts.ratingSource = .artist
    XCTAssertEqual(note(facts), "From an artist you rated 5")
    facts.ratingSource = .album
    XCTAssertEqual(note(facts), "From Budokan, an album you rated 5")
    facts.ratingSource = .song
    XCTAssertEqual(note(facts), "You rated this 5")
    XCTAssertEqual(MixReason.make(facts).kind, .rated)

    facts.explore = true
    XCTAssertEqual(note(facts), "Explore pick · new to you")
    XCTAssertEqual(MixReason.make(facts).kind, .explore)
    facts.lifetimePlays = 2
    XCTAssertEqual(note(facts), "Explore pick · rarely played")
    for (days, text) in [(3.0, "3 days"), (21, "3 weeks"), (150, "5 months")] {
      facts.lastHeard = now.addingTimeInterval(-days * 86400)
      XCTAssertEqual(note(facts), "Explore pick · not heard in \(text)")
    }
    // Heard within the day is no news; cooldowns do not rule it out.
    facts.lastHeard = now.addingTimeInterval(-3600)
    facts.lifetimePlays = 0
    XCTAssertEqual(note(facts), "Explore pick · rarely played")
  }

  /// The short label of an Up Next row, and the note standing in for it in
  /// a mix saved before labels.
  func testReasonLabels() throws {
    var facts = MixReason.Facts(artist: "BABYMETAL", album: "Budokan", now: now)
    XCTAssertEqual(MixReason.make(facts).label, "Fits what you play")
    facts.songPlays = 9
    XCTAssertEqual(MixReason.make(facts).label, "Played 9× lately")
    facts.likedAlbum = true
    XCTAssertEqual(MixReason.make(facts).label, "Album liked")
    facts.rating = 5
    XCTAssertEqual(MixReason.make(facts).label, "Rated 5")
    facts.ratingSource = .artist
    XCTAssertEqual(MixReason.make(facts).label, "Artist rated 5")
    facts.explore = true
    XCTAssertEqual(MixReason.make(facts).label, "Explore pick · new to you")

    let saved = Data(#"{"kind":"rated","note":"You rated this 5"}"#.utf8)
    let old = try JSONDecoder().decode(MixReason.self, from: saved)
    XCTAssertEqual(old.label, "You rated this 5")
  }

  /// Each pick carries its song id and a reason worded from the 60-day plays.
  func testPicksCarryTheirReason() {
    let first = song("s1", artistId: "ar1", artist: "Artist One", album: "a1")
    let index = SmartPlaybackService.LibraryIndex(songs: [first.playbackID: .init(first)])
    var rng = SplitMix64(seed: 1)
    let pick = MixRanker().rank(
      library: [first], index: index, affinity: AffinitySnapshot(), journal: JournalSnapshot(),
      pendingPlays: [:], recentPlays: ["s1": 4], ratings: [:], starred: [], likedAlbums: [],
      likedArtists: [], mode: .playSomething, count: 1, now: now, rng: &rng
    ).record.picks.first
    XCTAssertEqual(pick?.songId, "s1")
    XCTAssertEqual(pick?.why.note, "Artist One is your most-played artist")
  }

  func testSummaryGroupsArtistsAndSplitsRatings() {
    let songs = [
      song("s1", artistId: "ar1", artist: "Babymetal", album: "a1"),
      song("s2", artistId: "ar2", artist: "BABYMETAL", album: "a2"),
      song("s3", artistId: "ar3", artist: "Metalverse", album: "a3"),
    ]
    // Two spellings of one artist share an identity.
    let keys = ["ar1": "mbz:bm", "ar2": "mbz:bm", "ar3": "ar3"]
    let index = SmartPlaybackService.LibraryIndex(
      songs: Dictionary(
        uniqueKeysWithValues: songs.map { ($0.playbackID, .init($0, artistKeys: keys)) }))
    let artists = [
      Artist(id: "ar2", name: "BABYMETAL", albumCount: 2, mbzArtistID: "bm"),
      Artist(id: "ar3", name: "METALVERSE", albumCount: 1, mbzArtistID: nil),
    ]
    let record = MixRecord(
      at: now, mode: "playSomething",
      picks: ["s1", "s2", "s3"].enumerated().map { i, id in
        MixRecord.Pick(
          slot: "preferred", songId: id, title: id, artist: "",
          why: MixReason.make(.init(explore: i == 2, starred: i == 1)), reason: "", scores: "")
      }, eligible: 3, exploreShare: 0.33, notes: [])
    let skipped = PlaybackJournal.SkippedSong(
      songId: "s3", title: "Song s3", artist: "Metalverse", albumId: "a3", count: 2, latest: now)

    let summary = TasteSummary.build(
      latest: record, plays: ["s1": 3, "s2": 4, "s3": 5, "gone": 9], library: songs,
      index: index, artists: artists, songRatings: ["s1": 5, "s3": 1, "s2": 3],
      artistRatings: ["ar3": 5, "unknown": 1], skipped: [skipped], now: now)

    XCTAssertEqual(summary.recipeSize, 3)
    XCTAssertEqual(summary.recipe, [.history: 1, .liked: 1, .explore: 1])
    XCTAssertEqual(summary.top.map(\.name), ["BABYMETAL", "METALVERSE"])
    XCTAssertEqual(summary.top.map(\.plays), [7, 5])
    XCTAssertEqual(summary.top.first?.albumId, "a2")
    XCTAssertEqual(summary.boosted.map(\.title), ["METALVERSE", "Song s1"])
    XCTAssertEqual(summary.avoided.map(\.id), ["s3"])
    XCTAssertEqual(summary.skips.map(\.subtitle), ["Skipped twice · less likely for about 2 weeks"])
  }

  func testSkipLinesCountDownTheWindow() {
    func line(count: Int, daysAgo: Double) -> String {
      TasteSummary.skipLine(
        .init(
          songId: "s", title: "", artist: "", albumId: "", count: count,
          latest: now.addingTimeInterval(-daysAgo * 86400)), now: now)
    }
    XCTAssertEqual(line(count: 1, daysAgo: 0), "Skipped today · less likely for about 2 weeks")
    XCTAssertEqual(line(count: 1, daysAgo: 10), "Skipped 10 days ago · less likely for 4 more days")
    XCTAssertEqual(line(count: 4, daysAgo: 13.5), "Skipped 4 times · less likely for 1 more day")
  }

  /// The saved mixes come back for their own account only.
  @MainActor func testSavedMixesBelongToTheirAccount() throws {
    let pick = MixRecord.Pick(
      slot: "explore", songId: "s1", title: "t", artist: "a",
      why: MixReason.make(.init(explore: true)), reason: "r", scores: "")
    let record = MixRecord(
      at: now, mode: "playSomething", picks: [pick], eligible: 1, exploreShare: 1, notes: ["n"])
    let data = try JSONEncoder().encode(RecommendationLog.Saved(account: "srv|u1", mixes: [record]))
    XCTAssertEqual(
      RecommendationLog.restore(data, account: "srv|u1").first?.picks.first?.why, pick.why)
    XCTAssertTrue(RecommendationLog.restore(data, account: "srv|u2").isEmpty)
    XCTAssertTrue(RecommendationLog.restore(Data("{}".utf8), account: "srv|u1").isEmpty)
  }
}
