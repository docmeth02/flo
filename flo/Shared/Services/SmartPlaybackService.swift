//
//  SmartPlaybackService.swift
//  flo
//

import CoreData
import Foundation

class SmartPlaybackService {
  static let shared = SmartPlaybackService()

  private init() {}

  /// Generate song recommendations based on on-device listening data.
  /// - Parameters:
  ///   - count: Number of songs to return
  ///   - context: Last played song for contextual continuity (nil for broad shuffle)
  ///   - currentQueue: Current queue items to exclude from results
  ///   - allSongs: Full song library
  ///   - albums: Album list (for genre data)
  func generateRecommendations(
    count: Int,
    context: QueueEntity? = nil,
    currentQueue: [QueueEntity] = [],
    allSongs: [Song],
    albums: [Album] = []
  ) -> [Song] {
    guard !allSongs.isEmpty else { return [] }

    let history = CoreDataManager.shared.getRecordsByEntity(entity: HistoryEntity.self)
    let artistFreqs = getArtistFrequencies(history: history)
    let recentArtists = getRecentArtists(history: history, days: 14)
    let allGenres = getTopGenres(albums: albums, artistFreqs: artistFreqs)
    let topGenreEntries = allGenres.sorted { $0.value > $1.value }.prefix(5)
    let topGenres = Dictionary(uniqueKeysWithValues: topGenreEntries.map { ($0.key, $0.value) })
    let albumGenreMap = buildAlbumGenreMap(albums: albums)

    let queueIds = Set(currentQueue.compactMap { $0.id })
    let recentlyPlayedIds = getRecentlyPlayedIds(history: history, minutes: 30)

    let maxArtistFreq = Double(artistFreqs.values.max() ?? 1)

    var scored: [(Song, Double)] = []

    for song in allSongs {
      if queueIds.contains(song.id) || queueIds.contains(song.mediaFileId) { continue }
      if recentlyPlayedIds.contains(song.title) { continue }

      var score = 0.0

      // Artist frequency (0.30)
      let freq = Double(artistFreqs[song.artist] ?? 0)
      score += (freq / maxArtistFreq) * 0.30

      // Starred (0.25)
      if song.starred {
        score += 0.25
      }

      // Recency boost (0.20)
      if recentArtists.contains(song.artist) {
        score += 0.20
      }

      // Genre match (0.15)
      let songGenre = albumGenreMap[song.albumId] ?? ""
      if !songGenre.isEmpty, topGenres[songGenre] != nil {
        score += 0.15
      }

      // Random factor (0.10)
      score += Double.random(in: 0...0.10)

      // Context boost: same artist/album/genre as last played
      if let ctx = context {
        if song.artist == (ctx.artistName ?? "") {
          score += 0.15
        }
        if song.albumId == (ctx.albumId ?? "") {
          score += 0.10
        }
      }

      scored.append((song, score))
    }

    // Weighted random selection from top candidates
    scored.sort { $0.1 > $1.1 }
    let poolSize = min(scored.count, count * 5)
    let pool = Array(scored.prefix(poolSize))

    return weightedRandomSelection(from: pool, count: min(count, pool.count))
  }

  // MARK: - Helpers

  private func getArtistFrequencies(history: [HistoryEntity]) -> [String: Int] {
    var freqs: [String: Int] = [:]
    for entry in history {
      if let artist = entry.artistName, !artist.isEmpty {
        freqs[artist, default: 0] += 1
      }
    }
    return freqs
  }

  private func getRecentArtists(history: [HistoryEntity], days: Int) -> Set<String> {
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    var artists: Set<String> = []
    for entry in history {
      if let ts = entry.timestamp, ts >= cutoff, let artist = entry.artistName {
        artists.insert(artist)
      }
    }
    return artists
  }

  private func getRecentlyPlayedIds(history: [HistoryEntity], minutes: Int) -> Set<String> {
    let cutoff = Calendar.current.date(byAdding: .minute, value: -minutes, to: Date()) ?? Date()
    var ids: Set<String> = []
    for entry in history {
      if let ts = entry.timestamp, ts >= cutoff, let name = entry.trackName {
        ids.insert(name)
      }
    }
    return ids
  }

  private func getTopGenres(albums: [Album], artistFreqs: [String: Int]) -> [String: Int] {
    var genreScores: [String: Int] = [:]
    for album in albums {
      if !album.genre.isEmpty {
        let weight = artistFreqs[album.artist] ?? artistFreqs[album.albumArtist] ?? 1
        genreScores[album.genre, default: 0] += weight
      }
    }
    return genreScores
  }

  private func buildAlbumGenreMap(albums: [Album]) -> [String: String] {
    var map: [String: String] = [:]
    for album in albums {
      if !album.genre.isEmpty {
        map[album.id] = album.genre
      }
    }
    return map
  }

  private func weightedRandomSelection(from pool: [(Song, Double)], count: Int) -> [Song] {
    guard !pool.isEmpty else { return [] }

    var remaining = pool
    var selected: [Song] = []

    for _ in 0..<count {
      guard !remaining.isEmpty else { break }

      let totalWeight = remaining.reduce(0.0) { $0 + $1.1 }
      guard totalWeight > 0 else {
        selected.append(contentsOf: remaining.prefix(count - selected.count).map { $0.0 })
        break
      }

      var roll = Double.random(in: 0..<totalWeight)
      var pickedIdx = 0
      for (idx, item) in remaining.enumerated() {
        roll -= item.1
        if roll <= 0 {
          pickedIdx = idx
          break
        }
      }

      selected.append(remaining[pickedIdx].0)
      remaining.remove(at: pickedIdx)
    }

    return selected
  }
}
