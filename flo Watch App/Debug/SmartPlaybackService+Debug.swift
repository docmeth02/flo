//
//  SmartPlaybackService+Debug.swift
//  flo Watch App
//

#if DEBUG
  import Foundation

  // Simulator verification only. FLO_DEBUG_MIX=play|keep builds a mix of that
  // mode a few seconds after launch without playing it and logs every pick
  // (keep continues from a song of the top artist); FLO_DEBUG_RNG_SEED=<n>
  // repeats a mix exactly; FLO_DEBUG_MIX_SONG=<playbackID> logs that song's
  // scores; FLO_DEBUG_MIX_TIMING=1 also times the ranker on a library
  // inflated to 20k songs.
  extension SmartPlaybackService {
    func runDebugLaunchActions() {
      let env = ProcessInfo.processInfo.environment
      guard let kind = env["FLO_DEBUG_MIX"] else { return }
      Task {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let library = await loadCachedLibrary()
        let index = await libraryIndex()
        let affinity = await ListeningHistoryStore.shared.snapshot()

        var mode = MixMode.playSomething
        if kind == "keep" {
          let top = affinity.aggregates[.artist]?.max { $0.value.weight < $1.value.weight }?.key
          // The top artist's song in the genre with the most songs.
          var genreSizes: [String: Int] = [:]
          for entry in index.songs.values {
            for genre in entry.genres { genreSizes[genre, default: 0] += 1 }
          }
          func size(_ song: Song) -> Int {
            index.songs[song.playbackID]?.genres.map { genreSizes[$0] ?? 0 }.max() ?? 0
          }
          if let song = library.songs.filter({ index.songs[$0.playbackID]?.artistKey == top })
            .max(by: { size($0) < size($1) })
          {
            let genres = Set(index.songs[song.playbackID]?.genres ?? [])
            debugLog(
              "mix seed: \(song.playbackID) \(song.title) — \(song.artist) album=\(song.albumId) "
                + "genres=\(genres.sorted())")
            mode = .keepPlaying(
              KeepPlayingContext(
                seed: Seed(artist: song.artist, albumId: song.albumId), anchorGenres: genres,
                sessionMinutes: 20, queueIds: []))
          }
        }

        guard let record = await mix(count: kind == "keep" ? 10 : 15, mode: mode).record else {
          debugLog("mix: no songs")
          return
        }
        for (n, pick) in record.picks.enumerated() {
          debugLog(
            "pick \(n + 1) \(pick.slot): \(pick.title) — \(pick.artist) · \(pick.reason) · "
              + pick.scores)
        }
        debugLog(
          "mix record: mode=\(record.mode) eligible=\(record.eligible) "
            + "explore=\(String(format: "%.2f", record.exploreShare)) notes=\(record.notes)")

        let journal = await PlaybackJournal.shared.snapshot()
        for (id, events) in journal.skips {
          debugLog(
            "skip \(id): \(events.count) events P_song="
              + String(format: "%.3f", MixRanker().skipPenalty(events, now: Date())))
        }
        let ratings = await MainActor.run { RatingStore.shared.ratings }

        // The scores of one song, ranked alone: priors differ from a full
        // library, cooldown, skips and ratings do not.
        if let id = env["FLO_DEBUG_MIX_SONG"],
          let song = library.songs.first(where: { $0.playbackID == id })
        {
          var rng = SplitMix64(seed: 1)
          let alone = MixRanker().rank(
            library: [song], index: index, affinity: affinity, journal: journal,
            ratings: ratings, starred: library.starredIds, mode: mode, count: 1, now: Date(),
            rng: &rng)
          debugLog(
            "song \(id) \(song.title): "
              + (alone.record.picks.first.map { "\($0.slot) \($0.scores)" } ?? "excluded"))
        }

        guard env["FLO_DEBUG_MIX_TIMING"] == "1", !library.songs.isEmpty else { return }
        // Copies under new ids and titles, indexed like the songs they copy.
        var inflated = library.songs
        var entries = index.songs
        var copy = 0
        while inflated.count < 20000 {
          copy += 1
          for song in library.songs where inflated.count < 20000 {
            var twin = Song(
              id: "\(song.id)-\(copy)", title: "\(song.title) \(copy)", albumId: song.albumId,
              albumName: song.albumName, artist: song.artist, trackNumber: song.trackNumber,
              discNumber: song.discNumber, bitRate: song.bitRate, sampleRate: song.sampleRate,
              suffix: song.suffix, duration: song.duration,
              mediaFileId: "\(song.playbackID)-\(copy)")
            twin.genre = song.genre
            twin.genres = song.genres
            twin.year = song.year
            twin.playCount = song.playCount
            twin.artistId = song.artistId
            entries[twin.playbackID] = index.songs[song.playbackID]
            inflated.append(twin)
          }
        }
        let inflatedIndex = LibraryIndex(songs: entries)
        for _ in 0..<3 {
          var rng = SplitMix64(seed: 1)
          let started = DispatchTime.now().uptimeNanoseconds
          let result = MixRanker().rank(
            library: inflated, index: inflatedIndex, affinity: affinity, journal: journal,
            ratings: ratings, starred: library.starredIds, mode: mode, count: 15, now: Date(),
            rng: &rng)
          debugLog(
            "mix timing: \(inflated.count) songs, \(result.songs.count) picked in "
              + String(
                format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
        }
      }
    }
  }
#endif
