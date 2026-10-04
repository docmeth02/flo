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
      ratings: [:], starred: [], mode: .playSomething, count: count, now: now, rng: &rng
    ).songs
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
}
