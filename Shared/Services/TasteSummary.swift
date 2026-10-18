//
//  TasteSummary.swift
//  Ownwave
//

import Foundation

/// What Play Something learns from, for the Taste screen: the latest mix's
/// recipe, the artists of the last 60 days, the boosted and avoided songs
/// and artists, and the songs skipped lately.
struct TasteSummary: Sendable {
  struct TopArtist: Sendable, Identifiable {
    /// The artist key: spellings of one artist share their plays.
    let id: String
    let name: String
    /// Nil for an artist the cached list does not know.
    let artist: Artist?
    let plays: Int
    /// The album of the artist's most-played song, for its cover hue.
    let albumId: String
  }

  struct Rated: Sendable, Identifiable {
    enum Kind: Sendable { case song, artist }

    let kind: Kind
    /// The song's playback id or the artist's id.
    let id: String
    let title: String
    let subtitle: String
    let albumId: String
  }

  struct Skip: Sendable, Identifiable {
    var id: String { songId }
    let songId: String
    let title: String
    let subtitle: String
    let albumId: String
  }

  /// The latest played mix's picks per kind; nil before the first one.
  var recipe: [MixReason.Kind: Int]?
  var recipeSize = 0
  var top: [TopArtist] = []
  var boosted: [Rated] = []
  var avoided: [Rated] = []
  var skips: [Skip] = []

  private static let topCount = 20

  static func build(
    latest: MixRecord?, plays: [String: Int], library: [Song],
    index: SmartPlaybackService.LibraryIndex, artists: [Artist], songRatings: [String: Int],
    artistRatings: [String: Int], skipped: [PlaybackJournal.SkippedSong], now: Date
  ) -> TasteSummary {
    var summary = TasteSummary()
    if let latest {
      summary.recipe = Dictionary(grouping: latest.picks, by: \.why.kind).mapValues(\.count)
      summary.recipeSize = latest.picks.count
    }

    let songs = Dictionary(library.map { ($0.playbackID, $0) }) { first, _ in first }
    let artistsById = Dictionary(artists.map { ($0.id, $0) }) { first, _ in first }

    // Most-played songs first: an artist takes the spelling, the listed
    // artist and the album of its most-played song that has them.
    var groups: [String: (plays: Int, artist: Artist?, name: String, albumId: String)] = [:]
    let byPlays = plays.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    for (id, count) in byPlays {
      guard let entry = index.songs[id], !entry.artistKey.isEmpty, let song = songs[id] else {
        continue
      }
      var group = groups[entry.artistKey] ?? (0, nil, song.artist, song.albumId)
      group.plays += count
      if group.artist == nil, let artistId = entry.artistId, let artist = artistsById[artistId] {
        group.artist = artist
        group.name = artist.name
      }
      groups[entry.artistKey] = group
    }
    summary.top = groups.map {
      TopArtist(
        id: $0.key, name: $0.value.name, artist: $0.value.artist, plays: $0.value.plays,
        albumId: $0.value.albumId)
    }
    .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
    .prefix(topCount).map { $0 }

    func rated(_ stars: Int) -> [Rated] {
      let rows = songRatings.filter { $0.value == stars }.compactMap { id, _ in
        songs[id].map {
          Rated(kind: .song, id: id, title: $0.title, subtitle: "\($0.artist) · song", albumId: $0.albumId)
        }
      }
      let artistRows = artistRatings.filter { $0.value == stars }.compactMap { id, _ in
        artistsById[id].map {
          Rated(kind: .artist, id: id, title: $0.name, subtitle: "Artist", albumId: "")
        }
      }
      return (rows + artistRows).sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
    summary.boosted = rated(5)
    summary.avoided = rated(1)

    summary.skips = skipped.map {
      Skip(
        songId: $0.songId, title: $0.title, subtitle: skipLine($0, now: now), albumId: $0.albumId)
    }
    return summary
  }

  /// "Skipped twice · less likely for about 2 weeks": each skip weighs on the
  /// song for the journal's 14-day window, less as it ages.
  static func skipLine(_ song: PlaybackJournal.SkippedSong, now: Date) -> String {
    let skipped: String
    switch song.count {
    case 1:
      let calendar = Calendar.current
      if calendar.isDate(song.latest, inSameDayAs: now) {
        skipped = "Skipped today"
      } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
        calendar.isDate(song.latest, inSameDayAs: yesterday)
      {
        skipped = "Skipped yesterday"
      } else {
        skipped = "Skipped \(max(2, Int(now.timeIntervalSince(song.latest) / 86400))) days ago"
      }
    case 2: skipped = "Skipped twice"
    default: skipped = "Skipped \(song.count) times"
    }
    let left = PlaybackJournal.skipWindow - now.timeIntervalSince(song.latest)
    let days = max(1, Int((left / 86400).rounded(.up)))
    return skipped + " · less likely for " + (days >= 10 ? "about 2 weeks" : counted(days, "more day"))
  }

  /// Reads everything from the stores and caches; asks the server nothing.
  @MainActor static func load() async -> TasteSummary {
    let now = Date()
    async let plays = ListeningHistoryStore.shared.playCounts(
      since: now.addingTimeInterval(-SmartPlaybackService.reasonWindow))
    async let skipped = PlaybackJournal.shared.recentSkips()
    async let library = SmartPlaybackService.shared.loadCachedLibrary()
    async let index = SmartPlaybackService.shared.libraryIndex(allowSync: false)
    let latest = RecommendationLog.shared.played.first
    let ratings = RatingStore.shared
    let (songRatings, artistRatings) = (ratings.ratings, ratings.artistRatings)
    let inputs = (await plays, await skipped, await library.songs, await index)
    return await Task.detached(priority: .userInitiated) {
      build(
        latest: latest, plays: inputs.0, library: inputs.2, index: inputs.3,
        artists: LibraryCacheManager.shared.load([Artist].self, forKey: .artists) ?? [],
        songRatings: songRatings, artistRatings: artistRatings, skipped: inputs.1, now: now)
    }.value
  }
}
