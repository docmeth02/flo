//
//  SmartPlaybackService+Debug.swift
//  flo
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
    static var debugSeed: UInt64? {
      ProcessInfo.processInfo.environment["FLO_DEBUG_RNG_SEED"].flatMap(UInt64.init)
    }

    func runDebugLaunchActions() {
      let env = ProcessInfo.processInfo.environment
      if let spec = env["FLO_DEBUG_MIX_SIM"] {
        Task {
          try? await Task.sleep(nanoseconds: 6_000_000_000)
          await simulateMixes(spec: spec)
        }
      }
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
          if let song = library.songs.filter({
            index.songs[$0.playbackID]?.historyArtistKey == top
          })
          .max(by: { size($0) < size($1) }) {
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
              + pick.scores + " · why=\(pick.why.kind.rawValue) \(pick.why.note)")
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
        let pendingPlays = Self.latestListens(await ScrobbleQueueManager.shared.pendingListens())
        let liked = await likedCollections(index: index)
        let (ratings, starred) = await MainActor.run { [songs = library.songs] in
          (
            Self.effectiveRatings(of: songs, index: index),
            StarStore.shared.starred(listed: library.starredIds)
          )
        }

        // The scores of one song, ranked alone: priors differ from a full
        // library, cooldown, skips and ratings do not.
        if let id = env["FLO_DEBUG_MIX_SONG"],
          let song = library.songs.first(where: { $0.playbackID == id })
        {
          var rng = SplitMix64(seed: 1)
          let alone = MixRanker().rank(
            library: [song], index: index, affinity: affinity, journal: journal,
            pendingPlays: pendingPlays, ratings: ratings, starred: starred,
            likedAlbums: liked.albums, likedArtists: liked.artists, mode: mode, count: 1,
            now: Date(), rng: &rng)
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
            pendingPlays: pendingPlays, ratings: ratings, starred: starred,
            likedAlbums: liked.albums, likedArtists: liked.artists, mode: mode, count: 15,
            now: Date(), rng: &rng)
          debugLog(
            "mix timing: \(inflated.count) songs, \(result.songs.count) picked in "
              + String(
                format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
        }
      }
    }
  }

  extension SmartPlaybackService {
    /// FLO_DEBUG_MIX_SIM=<days>:<sessions a day>:<songs>:<continuation songs>[:<offline pool>]
    /// replays sessions of Play Something plus a Keep Playing continuation on
    /// this account's snapshots, in memory only. A pick is skipped with
    /// FLO_DEBUG_MIX_SIM_SKIP (default 0.1), else heard and folded into the
    /// affinities like a server play; the journal forgets after 48 h as the
    /// real one does. FLO_DEBUG_MIX_SIM_SEEDS runs that many seeds (default 3),
    /// FLO_DEBUG_MIX_VARIETY=familiar|balanced|adventurous picks the variety.
    /// Nothing is played or scrobbled.
    func simulateMixes(spec: String) async {
      let env = ProcessInfo.processInfo.environment
      let parts = spec.split(separator: ":").compactMap { Int($0) }
      let days = parts.first ?? 28
      let perDay = parts.count > 1 ? parts[1] : 1
      let count = parts.count > 2 ? parts[2] : 15
      let keepCount = parts.count > 3 ? parts[3] : 10
      let offlinePool = parts.count > 4 ? parts[4] : 0
      let skipRate = env["FLO_DEBUG_MIX_SIM_SKIP"].flatMap(Double.init) ?? 0.1
      let seeds = env["FLO_DEBUG_MIX_SIM_SEEDS"].flatMap(Int.init) ?? 3

      // A fresh login imports its history and ratings first.
      _ = await syncSongLibrary()
      await RatingStore.shared.refreshIfStale(waitingAtMost: .seconds(5))
      for _ in 0..<60 {
        if await ListeningHistoryStore.shared.snapshot().state.bootstrapComplete { break }
        await ListeningHistoryStore.shared.refreshIfStale(reason: .debug)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      let cached = await loadCachedLibrary()
      let index = await libraryIndex()
      let startAffinity = await ListeningHistoryStore.shared.snapshot()
      let startJournal = await PlaybackJournal.shared.snapshot()
      let liked = await likedCollections(index: index)
      let (ratings, starred) = await MainActor.run { [songs = cached.songs] in
        (
          Self.effectiveRatings(of: songs, index: index),
          StarStore.shared.starred(listed: cached.starredIds)
        )
      }
      let variety = env["FLO_DEBUG_MIX_VARIETY"].flatMap(MixRanker.Variety.init) ?? .balanced
      let config = MixRanker.Config(variety: variety)
      // Offline: the most played songs of the account, as downloads tend to be.
      var library = cached.songs
      if offlinePool > 0 {
        library = Array(
          library.sorted {
            (startAffinity.aggregates[.song]?[$0.playbackID]?.weight ?? 0, $0.playCount ?? 0)
              > (startAffinity.aggregates[.song]?[$1.playbackID]?.weight ?? 0, $1.playCount ?? 0)
          }
          .prefix(offlinePool))
      }
      let rated = ratings.filter { $0.value.stars > 0 }.count
      debugLog(
        "sim: account plays=\(startAffinity.aggregates[.song]?.values.reduce(0) { $0 + $1.plays } ?? 0) "
          + "library=\(library.count) rated=\(rated) starred=\(starred.count) "
          + "variety=\(variety.rawValue) spec=\(spec) skip=\(skipRate)")

      func titleKey(_ song: Song) -> String {
        let title = song.title.lowercased()
        let cut = title.firstIndex { "([｜【".contains($0) } ?? title.endIndex
        return title[..<cut].trimmingCharacters(in: .whitespaces)
      }

      for seed in 1...seeds {
        var rng = SplitMix64(seed: UInt64(seed))
        var affinity = startAffinity
        var journal = startJournal
        let start = Date()
        var affinityAt = start
        var heardCount: [String: Int] = [:]
        var lastHeard: [String: Date] = [:]
        var titleLastHeard: [String: Date] = [:]
        var names: [String: String] = [:]
        var intervals: [Double] = []
        var recentRepeats = 0
        var titleRepeats = 0
        var heardTotal = 0
        var picksTotal = 0
        var shortMixes = 0
        var explore = 0
        var weekly: [Set<String>] = []

        func fold(_ kind: AffinitySnapshot.Kind, _ key: String, _ weight: Double, at: Date) {
          guard !key.isEmpty else { return }
          let old = affinity.aggregates[kind]?[key]
          affinity.aggregates[kind, default: [:]][key] = AffinitySnapshot.Aggregate(
            weight: (old?.weight ?? 0) + weight, lastPlayAt: at, plays: (old?.plays ?? 0) + 1)
        }

        for day in 0..<days {
          if day % 7 == 0 { weekly.append([]) }
          for session in 0..<perDay {
            var now = start.addingTimeInterval(
              Double(day) * 86400 + Double(session) * 86400 / Double(perDay))
            let decay = exp2(-now.timeIntervalSince(affinityAt) / ListeningHistoryStore.halfLife)
            for (kind, rows) in affinity.aggregates {
              affinity.aggregates[kind] = rows.mapValues {
                AffinitySnapshot.Aggregate(
                  weight: $0.weight * decay, lastPlayAt: $0.lastPlayAt, plays: $0.plays)
              }
            }
            affinityAt = now
            journal.lastHeardAt = journal.lastHeardAt.filter {
              now.timeIntervalSince($0.value) < 48 * 3600
            }
            var queue = Set<String>()
            var genres = Set<String>()
            var last: Song?
            for (part, wanted) in [count, keepCount].enumerated() where wanted > 0 {
              let mode: MixMode =
                part == 0 || last == nil
                ? .playSomething
                : .keepPlaying(
                  KeepPlayingContext(
                    seed: Seed(artist: last!.artist, albumId: last!.albumId),
                    anchorGenres: genres, sessionMinutes: Double(count) * 4, queueIds: queue))
              let (songs, record) = MixRanker(config: config).rank(
                library: library, index: index, affinity: affinity, journal: journal,
                pendingPlays: [:], ratings: ratings, starred: starred, likedAlbums: liked.albums,
                likedArtists: liked.artists, mode: mode, count: wanted, now: now, rng: &rng)
              if songs.count < wanted { shortMixes += 1 }
              explore += record.picks.filter { $0.slot == "explore" }.count
              picksTotal += songs.count
              for song in songs {
                let id = song.playbackID
                queue.insert(id)
                names[id] = "\(song.title) — \(song.artist)"
                let entry =
                  index.songs[id] ?? LibraryIndex.Entry(song, artistKeys: index.artistKeys)
                if Double.random(in: 0..<1, using: &rng) < skipRate {
                  journal.lastHeardAt[id] = now
                  journal.skips[id, default: []].append(
                    JournalSnapshot.SkipEvent(at: now, weight: 1, artistKey: entry.artistKey))
                  now += 20
                  continue
                }
                if let before = lastHeard[id] {
                  let gap = now.timeIntervalSince(before) / 86400
                  intervals.append(gap)
                  if gap < 3 { recentRepeats += 1 }
                }
                let title = titleKey(song)
                if let before = titleLastHeard[title], now.timeIntervalSince(before) < 3 * 86400 {
                  titleRepeats += 1
                }
                lastHeard[id] = now
                titleLastHeard[title] = now
                heardCount[id, default: 0] += 1
                heardTotal += 1
                weekly[weekly.count - 1].insert(id)
                journal.lastHeardAt[id] = now
                fold(.song, id, 1, at: now)
                fold(.artist, entry.historyArtistKey, 1, at: now)
                fold(.album, entry.albumId, 1, at: now)
                for genre in entry.genres {
                  fold(.genre, genre, 1 / Double(entry.genres.count), at: now)
                }
                if let era = entry.era { fold(.era, era, 1, at: now) }
                genres.formUnion(entry.genres)
                last = song
                now += song.duration > 0 ? song.duration : 240
              }
            }
          }
        }

        let ranked = heardCount.sorted { $0.value > $1.value }
        let top10 = ranked.prefix(10).reduce(0) { $0 + $1.value }
        let sortedGaps = intervals.sorted()
        let median = sortedGaps.isEmpty ? 0 : sortedGaps[sortedGaps.count / 2]
        let weeks = weekly.filter { !$0.isEmpty }
        debugLog(
          "sim seed \(seed): heard \(heardTotal) of \(picksTotal) picks, "
            + "\(heardCount.count) songs, "
            + String(
              format: "repeats<3d %.0f %% (titles %.0f %%), top10 %.0f %%, ",
              100 * Double(recentRepeats) / Double(max(1, heardTotal)),
              100 * Double(titleRepeats) / Double(max(1, heardTotal)),
              100 * Double(top10) / Double(max(1, heardTotal)))
            + "max \(ranked.first?.value ?? 0)×, "
            + String(format: "median gap %.1f d, ", median)
            + "weekly songs \(weeks.map(\.count).reduce(0, +) / max(1, weeks.count)), "
            + "explore \(explore), short \(shortMixes)")
        if seed == 1 {
          for (id, n) in ranked.prefix(8) { debugLog("sim top \(n)× \(names[id] ?? id)") }
        }
      }
    }
  }

  extension MixRanker {
    /// The song's penalty from its own skips.
    func skipPenalty(_ events: [JournalSnapshot.SkipEvent], now: Date) -> Double {
      config.skipPenalty * min(config.skipLoadCap, skipLoad(events, now: now))
    }
  }
#endif
