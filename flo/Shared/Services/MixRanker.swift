//
//  MixRanker.swift
//  flo
//

import Foundation

/// Scores the library for one mix and samples it: mostly preferred songs by
/// affinity, ratings and stars, plus a share of lesser-played songs from the
/// listener's own artists and genres. Pure and synchronous: every input is a
/// snapshot, so the same inputs and generator state give the same mix.
/// Which caps a refill may step over.
private enum Relax { case none, genre, all }

struct MixRanker {
  struct Config {
    // Saturation points of the affinity features: f(x; k) reaches 1 at x = k.
    var artistK = 40.0
    var albumK = 15.0
    var genreK = 80.0
    var eraK = 120.0
    var songK = 8.0
    /// Server play counts above this add nothing to a song's prior.
    var priorPlayCap = 10
    /// Decayed history at which the log is trusted fully over server counts.
    var fullTrustWeight = 40.0
    /// Trust in the log while its import has not reached the oldest play.
    var partialImportTrust = 0.5
    /// Below this much decayed history the mix starts cold.
    var coldStartWeight = 20.0

    var baseWeight = 0.02
    var artistWeight = 0.24
    var albumWeight = 0.10
    var genreWeight = 0.16
    var eraWeight = 0.04
    var songWeight = 0.16
    var starWeight = 0.25
    var boostBonus = 0.35
    var ratedFourBonus = 0.20
    var ratedTwoMultiplier = 0.02
    /// Added for a song on a liked album or by a liked artist, together at
    /// most `collectionBonusCap`.
    var likedAlbumBonus = 0.10
    var likedArtistBonus = 0.08
    var collectionBonusCap = 0.15

    var skipHalfLife: TimeInterval = 14 * 86400
    var skipPenalty = 0.15
    var skipLoadCap = 2.0
    var artistSkipPenalty = 0.05
    var artistSkipMinSongs = 3
    var artistSkipDamping = 5.0

    var cooldownFloor = 0.05
    var cooldownHours = 6.0
    var titleCooldownFloor = 0.10
    var titleCooldownHours = 2.0
    /// Title siblings heard longer ago than this are fully cooled down.
    var titleCooldownWindow: TimeInterval = 24 * 3600

    var clusterArtistWeight = 3.0
    var clusterGenreWeight = 8.0
    var clusterGenreArtists = 3
    var exploreBase = 0.25
    var exploreMaxPlays = 2

    var playSomethingExplore = 1.0 / 6
    var keepPlayingExplore = 1.0 / 3
    var keepPlayingExploreMax = 0.40
    var keepPlayingRampMinutes = 90.0

    /// Preferred songs are sampled from this many candidates per wanted song.
    var preferredPoolFactor = 5
    /// Sampling weighs a preferred song by its weight to this power, so
    /// favourites stand out of a long tail of weak songs.
    var preferredSamplingExponent = 2.0
    var poolPerArtist = 4

    var perArtistCap = 2
    var perAlbumCap = 2
    var genreCeiling = 0.60

    var anchorGenreBonus = 0.15
    var seedArtistBonus = 0.15
    var seedAlbumPenalty = 0.12
    /// Anchor genres bound the candidates while this many per wanted song remain.
    var anchorMinFactor = 3
  }

  var config = Config()

  /// A song's rating for the mix and whose it is: the song's own, else its
  /// album's, else its artist's.
  struct Rating: Sendable, Equatable {
    enum Source: String, Sendable {
      case song, album, artist
    }

    let stars: Int
    let source: Source
  }

  private struct Candidate {
    let index: Int
    var artist = 0.0
    var album = 0.0
    var genre = 0.0
    var era = 0.0
    var song = 0.0
    var rating = 0
    var ratingSource = Rating.Source.song
    var starred = false
    var likedAlbum = false
    var likedArtist = false
    var collection = 0.0
    var skip = 0.0
    var pressure = 0.0
    var cool = 1.0
    var context = 0.0
    var anchored = false
    var seedArtist = false
    var preferred = 0.0
    var explore = 0.0
  }

  /// What the scoring needs of an artist, looked up once per song.
  private struct ArtistStats {
    var prior = 0.0
    var songs = 0
    var plays: [Int] = []
    var feature = 0.0
    var pressure = 0.0
    var cluster = false
    /// The most plays a song in the lower half of the artist's catalogue has.
    var lowerHalf: Int?
  }

  private enum Slot {
    case preferred, explore
  }

  /// How a pick got into the mix, for diagnostics.
  private enum Source: String {
    case explore, sampled, remainder
    case relaxedGenre = "relaxed genre"
    case relaxedCaps = "relaxed caps"
  }

  private enum Admission {
    case taken, capped, rejected
  }

  // MARK: - Ranking

  /// `pendingPlays` are the latest listens per song still in the outbox: the
  /// server's log has not counted them yet, so they only cool their songs
  /// down, like the journal's. `likedAlbums` are album ids, `likedArtists`
  /// artist keys.
  func rank(
    library: [Song], index: SmartPlaybackService.LibraryIndex, affinity: AffinitySnapshot,
    journal: JournalSnapshot, pendingPlays: [String: Date], ratings: [String: Rating],
    starred: Set<String>, likedAlbums: Set<String>, likedArtists: Set<String>,
    mode: SmartPlaybackService.MixMode, count: Int, now: Date,
    rng: inout some RandomNumberGenerator
  ) -> (songs: [Song], record: MixRecord) {
    let cfg = config
    var notes: [String] = []

    let artistAgg = Self.artistAffinity(affinity.aggregates[.artist] ?? [:], index: index)
    let albumAgg = affinity.aggregates[.album] ?? [:]
    let genreAgg = affinity.aggregates[.genre] ?? [:]
    let eraAgg = affinity.aggregates[.era] ?? [:]
    let songAgg = affinity.aggregates[.song] ?? [:]

    // How far the log is trusted over the server's play counts.
    let totalWeight = songAgg.values.reduce(0) { $0 + $1.weight }
    var trust = min(1, totalWeight / cfg.fullTrustWeight)
    if !affinity.state.bootstrapComplete { trust = min(trust, cfg.partialImportTrust) }

    var context: SmartPlaybackService.KeepPlayingContext?
    if case .keepPlaying(let keep) = mode { context = keep }
    let modeName = context == nil ? "playSomething" : "keepPlaying"

    // Skips and the seed name artists; the library maps names to artist keys.
    var wantedNames = Set<String>()
    if let context, let name = ArtistIdentity.key(name: context.seed.artist, mbid: nil) {
      wantedNames.insert(name)
    }
    for (id, events) in journal.skips where index.songs[id] == nil {
      wantedNames.formUnion(events.map(\.artistKey))
    }
    wantedNames.remove("")

    // Pass 1: keys, server-count priors, catalogue plays and title cooldowns.
    let ids = library.map(\.playbackID)
    let entries = library.indices.map {
      index.songs[ids[$0]]
        ?? SmartPlaybackService.LibraryIndex.Entry(library[$0], artistKeys: index.artistKeys)
    }
    var artists: [String: ArtistStats] = [:]
    var albumPrior: [String: Double] = [:]
    var genrePrior: [String: Double] = [:]
    var eraPrior: [String: Double] = [:]
    var artistIds: [String: String] = [:]
    var foldedNames: [String: String] = [:]
    var genreArtists: [String: Set<String>] = [:]
    var favouredArtists = likedArtists
    var recentTitles: [String: Date] = [:]
    var recentTitleArtists = Set<String>()
    var recentTitleStarts = Set<String>()
    var titleKeys: [Int: String] = [:]
    var lifetimePlays = [Int](repeating: 0, count: library.count)
    var songWeights = [Double](repeating: 0, count: library.count)
    var heardAt = [Date?](repeating: nil, count: library.count)

    func titleKey(_ i: Int) -> String {
      if let key = titleKeys[i] { return key }
      let key = entries[i].artistKey + "|" + SmartPlaybackService.normalizeTitle(library[i].title)
      titleKeys[i] = key
      return key
    }

    // Normalizing keeps a title's first character unless it opens with a
    // bracket or a space; anything else starting differently cannot be a
    // sibling of a recent title, and skips the slow normalization.
    func mayShareTitle(_ i: Int) -> Bool {
      guard recentTitleArtists.contains(entries[i].artistKey),
        let first = library[i].title.first.map({ $0.lowercased() })
      else { return false }
      return first == "(" || first == "[" || first.allSatisfy(\.isWhitespace)
        || recentTitleStarts.contains(entries[i].artistKey + "|" + first)
    }

    for i in library.indices {
      let song = library[i]
      let entry = entries[i]
      let aggregate = songAgg[ids[i]]
      let prior = Double(min(song.playCount ?? 0, cfg.priorPlayCap))
      songWeights[i] = aggregate?.weight ?? 0
      albumPrior[entry.albumId, default: 0] += prior
      for genre in entry.genres {
        genrePrior[genre, default: 0] += prior
        if aggregate != nil { genreArtists[genre, default: []].insert(entry.artistKey) }
      }
      if let era = entry.era { eraPrior[era, default: 0] += prior }

      // The server's count already includes the plays the log mirrors.
      let plays = max(aggregate?.plays ?? 0, song.playCount ?? 0)
      lifetimePlays[i] = plays
      artists[entry.artistKey, default: ArtistStats()].prior += prior
      artists[entry.artistKey, default: ArtistStats()].songs += 1
      artists[entry.artistKey, default: ArtistStats()].plays.append(plays)

      let rating = ratings[ids[i]]?.stars ?? 0
      if rating >= 4 || starred.contains(ids[i]) { favouredArtists.insert(entry.artistKey) }

      if !wantedNames.isEmpty {
        // Folding is slow; a library repeats few artist spellings.
        let name =
          foldedNames[song.artist] ?? ArtistIdentity.key(name: song.artist, mbid: nil) ?? ""
        foldedNames[song.artist] = name
        if wantedNames.contains(name), artistIds[name] == nil { artistIds[name] = entry.artistKey }
      }

      // Each source of a play cools it down once: the latest of them counts.
      let heard = [aggregate?.lastPlayAt, journal.lastHeardAt[ids[i]], pendingPlays[ids[i]]]
        .compactMap { $0 }.max()
      heardAt[i] = heard
      if let heard, now.timeIntervalSince(heard) < cfg.titleCooldownWindow {
        let key = titleKey(i)
        let title = key.dropFirst(entry.artistKey.count + 1)
        if let first = title.first {
          recentTitles[key] = max(recentTitles[key] ?? heard, heard)
          recentTitleArtists.insert(entry.artistKey)
          recentTitleStarts.insert(entry.artistKey + "|" + String(first))
        }
      }
    }

    // Skip pressure per song, and per artist once several of its songs were
    // skipped. Each song adds at most 1 to its artist; the artist's decayed
    // affinity weight (the snapshot's, 60-day half-life) dampens the pressure,
    // so an artist played a lot shrugs off a few skips.
    var songSkip: [String: Double] = [:]
    var artistSkips: [String: (songs: Int, load: Double)] = [:]
    for (id, events) in journal.skips {
      let load = skipLoad(events, now: now)
      songSkip[id] = load
      let name = events.first?.artistKey ?? ""
      let artist = index.songs[id]?.artistKey ?? artistIds[name] ?? name
      guard !artist.isEmpty else { continue }
      artistSkips[artist, default: (0, 0)].songs += 1
      artistSkips[artist, default: (0, 0)].load += min(1, load)
    }

    let seedArtist = context.map {
      let name = ArtistIdentity.key(name: $0.seed.artist, mbid: nil) ?? ""
      return artistIds[name] ?? name
    }
    let anchorGenres = context?.anchorGenres ?? []
    let queueIds = context?.queueIds ?? []

    // Features blend the log with the server's counts, once per key.
    func feature(_ weight: Double?, _ prior: Double, _ k: Double) -> Double {
      trust * saturate(weight ?? 0, k) + (1 - trust) * saturate(prior, k)
    }
    func features(
      _ aggregates: [String: AffinitySnapshot.Aggregate], _ priors: [String: Double], _ k: Double
    )
      -> [String: Double]
    {
      priors.reduce(into: [:]) { $0[$1.key] = feature(aggregates[$1.key]?.weight, $1.value, k) }
    }
    let albumFeature = features(albumAgg, albumPrior, cfg.albumK)
    let eraFeature = features(eraAgg, eraPrior, cfg.eraK)

    // Clusters: artists played a fair amount, liked or with a favoured song,
    // and genres played a fair amount across several artists.
    for (key, var artist) in artists {
      let weight = artistAgg[key]?.weight
      artist.feature = feature(weight, artist.prior, cfg.artistK)
      artist.cluster = (weight ?? 0) >= cfg.clusterArtistWeight || favouredArtists.contains(key)
      if artist.plays.count >= 2 {
        artist.lowerHalf = artist.plays.sorted()[artist.plays.count / 2 - 1]
      }
      if let skips = artistSkips[key], skips.songs >= cfg.artistSkipMinSongs {
        artist.pressure =
          cfg.artistSkipPenalty * skips.load / (skips.load + (weight ?? 0) + cfg.artistSkipDamping)
      }
      artist.plays = []
      artists[key] = artist
    }
    let genreStats = genrePrior.reduce(into: [String: (feature: Double, cluster: Bool)]()) {
      let weight = genreAgg[$1.key]?.weight ?? 0
      $0[$1.key] = (
        feature(weight, $1.value, cfg.genreK),
        weight >= cfg.clusterGenreWeight
          && (genreArtists[$1.key]?.count ?? 0) >= cfg.clusterGenreArtists
      )
    }

    // Pass 2: features, cooldowns and the weights of both pools.
    var candidates: [Candidate] = []
    candidates.reserveCapacity(library.count)
    for i in library.indices {
      let song = library[i]
      let entry = entries[i]
      let id = ids[i]
      // Lookups in empty dictionaries still hash, and most of these are empty.
      let rated = ratings.isEmpty ? nil : ratings[id]
      let rating = rated?.stars ?? 0
      if rating == 1 || (!queueIds.isEmpty && (queueIds.contains(song.id) || queueIds.contains(id)))
      {
        continue
      }

      var c = Candidate(index: i)
      let artist = artists[entry.artistKey] ?? ArtistStats()
      // A liked album's own songs count as a cluster.
      var inCluster = artist.cluster || likedAlbums.contains(entry.albumId)
      c.artist = artist.feature
      c.album = albumFeature[entry.albumId] ?? 0
      for genre in entry.genres {
        guard let stats = genreStats[genre] else { continue }
        c.genre = max(c.genre, stats.feature)
        inCluster = inCluster || stats.cluster
      }
      c.era = entry.era.flatMap { eraFeature[$0] } ?? 0
      c.song = feature(
        songWeights[i], Double(min(song.playCount ?? 0, cfg.priorPlayCap)), cfg.songK)
      c.rating = rating
      c.ratingSource = rated?.source ?? .song
      c.starred = !starred.isEmpty && starred.contains(id)
      c.likedAlbum = !likedAlbums.isEmpty && likedAlbums.contains(entry.albumId)
      c.likedArtist = !likedArtists.isEmpty && likedArtists.contains(entry.artistKey)
      c.collection = min(
        cfg.collectionBonusCap,
        (c.likedAlbum ? cfg.likedAlbumBonus : 0) + (c.likedArtist ? cfg.likedArtistBonus : 0))
      c.skip = songSkip.isEmpty ? 0 : cfg.skipPenalty * min(cfg.skipLoadCap, songSkip[id] ?? 0)
      c.pressure = artist.pressure

      if let heard = heardAt[i] {
        let hours = max(0, now.timeIntervalSince(heard)) / 3600
        c.cool = cfg.cooldownFloor + (1 - cfg.cooldownFloor) * (1 - exp(-hours / cfg.cooldownHours))
      }
      if !recentTitles.isEmpty, mayShareTitle(i), let heard = recentTitles[titleKey(i)] {
        let hours = max(0, now.timeIntervalSince(heard)) / 3600
        c.cool = min(
          c.cool,
          cfg.titleCooldownFloor + (1 - cfg.titleCooldownFloor)
            * (1 - exp(-hours / cfg.titleCooldownHours)))
      }

      if let context {
        c.anchored = entry.genres.contains { anchorGenres.contains($0) }
        c.seedArtist = !entry.artistKey.isEmpty && entry.artistKey == seedArtist
        let seedAlbum = !context.seed.albumId.isEmpty && entry.albumId == context.seed.albumId
        c.context =
          (c.anchored ? cfg.anchorGenreBonus : 0) + (c.seedArtist ? cfg.seedArtistBonus : 0)
          - (seedAlbum ? cfg.seedAlbumPenalty : 0)
      }

      let base =
        cfg.baseWeight + cfg.artistWeight * c.artist + cfg.albumWeight * c.album
        + cfg.genreWeight * c.genre + cfg.eraWeight * c.era + cfg.songWeight * c.song
        + (c.starred ? cfg.starWeight : 0) + c.collection + ratingBonus(rating) - c.skip
        - c.pressure + c.context
      c.preferred = c.cool * ratingMultiplier(rating) * max(0.01, base)

      // Lesser-played songs from the listener's own clusters, never one rated
      // down; skips hold them back as they do preferred songs.
      let plays = lifetimePlays[i]
      let lessPlayed = plays <= cfg.exploreMaxPlays || artist.lowerHalf.map { plays <= $0 } ?? false
      if inCluster, lessPlayed, rating == 0 || rating >= 3 {
        c.explore =
          c.cool
          * max(0, cfg.exploreBase + c.artist + c.genre + max(0, c.context) - c.skip - c.pressure)
          / (1 + Double(plays)).squareRoot()
      }
      candidates.append(c)
    }

    // The session's genres bound a continuation while enough songs share
    // them, by enough artists to fill the mix within the artist cap.
    if !anchorGenres.isEmpty {
      let anchored = candidates.filter(\.anchored)
      var perArtist: [String: Int] = [:]
      for c in anchored { perArtist[entries[c.index].artistKey, default: 0] += 1 }
      let fillable = perArtist.values.reduce(0) { $0 + min($1, cfg.perArtistCap) }
      let genres = anchorGenres.sorted().joined(separator: ", ")
      if anchored.count >= cfg.anchorMinFactor * count, fillable >= count {
        candidates = anchored
        notes.append("anchor genres: \(genres)")
      } else {
        notes.append(
          "anchor genres: \(genres) (\(anchored.count) songs by \(perArtist.count) artists, "
            + "not bounding)")
      }
    }

    // Cold start: anchor on ratings and stars, else on the server's counts,
    // widened to their artists and then their genres; with neither, every
    // artist is equally likely.
    var bootstrap = false
    if totalWeight < cfg.coldStartWeight {
      let favoured = candidates.filter { $0.rating >= 4 || $0.starred || $0.collection > 0 }
      let counted = candidates.filter { lifetimePlays[$0.index] > 0 }
      let seeds = favoured.isEmpty ? counted : favoured
      if seeds.isEmpty {
        bootstrap = true
        for n in candidates.indices {
          let artist = entries[candidates[n].index].artistKey
          candidates[n].preferred /= Double(max(1, artists[artist]?.songs ?? 1))
        }
        notes.append("bootstrap")
      } else {
        let seedArtists = Set(seeds.map { entries[$0.index].artistKey })
        let seedGenres = Set(seeds.flatMap { entries[$0.index].genres })
        var keep: (Candidate) -> Bool = { seedArtists.contains(entries[$0.index].artistKey) }
        var widened = "artists"
        if candidates.filter(keep).count < cfg.anchorMinFactor * count {
          keep = { !seedGenres.isDisjoint(with: entries[$0.index].genres) }
          widened = "genres"
          if candidates.filter(keep).count < cfg.anchorMinFactor * count {
            keep = { _ in true }
            widened = "library"
          }
        }
        for n in candidates.indices where !keep(candidates[n]) { candidates[n].preferred = 0 }
        notes.append(
          "cold start: \(favoured.isEmpty ? "server counts" : "ratings/stars"), their \(widened)")
      }
    }

    // Exploration quota: a fixed share for Play Something, growing with the
    // session for Keep Playing; the fraction is rounded at random.
    let share =
      context.map {
        cfg.keepPlayingExplore + (cfg.keepPlayingExploreMax - cfg.keepPlayingExplore)
          * min(max(0, $0.sessionMinutes) / cfg.keepPlayingRampMinutes, 1)
      } ?? cfg.playSomethingExplore
    let wanted = Double(count) * share
    let exploreQuota =
      Int(wanted) + (Double.random(in: 0..<1, using: &rng) < wanted - wanted.rounded(.down) ? 1 : 0)

    // Selection with caps per artist and album, and for Play Something a soft
    // ceiling per genre. A capped song waits in the overflow for a refill.
    var chosen = Set<Int>()
    var titles = Set<String>()
    var artistCounts: [String: Int] = [:]
    var albumCounts: [String: Int] = [:]
    var genreCounts: [String: Int] = [:]
    var overflow: [Int] = []
    let genreLimit = context == nil ? Int((Double(count) * cfg.genreCeiling).rounded(.up)) : count

    // The genre ceiling gives way first; the artist and album caps only when
    // the mix cannot be filled otherwise.
    func fits(_ n: Int, _ relax: Relax) -> Bool {
      let entry = entries[candidates[n].index]
      return artistCounts[entry.artistKey, default: 0] < cfg.perArtistCap
        && (entry.albumId.isEmpty || albumCounts[entry.albumId, default: 0] < cfg.perAlbumCap)
        && (relax == .genre
          || entry.genres.first.map { genreCounts[$0, default: 0] < genreLimit } ?? true)
    }
    func admit(_ n: Int, relax: Relax = .none) -> Admission {
      let i = candidates[n].index
      let entry = entries[i]
      guard !chosen.contains(n), !titles.contains(titleKey(i)) else { return .rejected }
      if relax != .all, !fits(n, relax) { return .capped }
      let genre = entry.genres.first
      chosen.insert(n)
      titles.insert(titleKey(i))
      artistCounts[entry.artistKey, default: 0] += 1
      albumCounts[entry.albumId, default: 0] += 1
      if let genre { genreCounts[genre, default: 0] += 1 }
      return .taken
    }

    // Exploration goes first, so its share survives the caps: an artist by
    // the mean weight of its songs left, so a large catalogue does not
    // crowd out a small one, then one of the artist's songs.
    var exploreSongs: [[Int]] = []
    var exploreTotals: [Double] = []
    var exploreSlot: [String: Int] = [:]
    for n in candidates.indices where candidates[n].explore > 0 {
      let artist = entries[candidates[n].index].artistKey
      if exploreSlot[artist] == nil {
        exploreSlot[artist] = exploreSongs.count
        exploreSongs.append([])
        exploreTotals.append(0)
      }
      let a = exploreSlot[artist]!
      exploreSongs[a].append(n)
      exploreTotals[a] += candidates[n].explore
    }
    let explorePool =
      "explore pool: \(exploreSongs.reduce(0) { $0 + $1.count }) songs by "
      + "\(exploreSongs.count) artists"
    var explorePicks: [Int] = []
    // One discovery per artist leaves the favourites room in the caps; the
    // artists' remaining songs are kept for a second round in case the
    // quota is not met with one each.
    var exploreReserve: [[Int]] = Array(repeating: [], count: exploreSongs.count)
    for round in 0..<2 {
      if round == 1 {
        guard explorePicks.count < exploreQuota else { break }
        for a in exploreReserve.indices where !exploreReserve[a].isEmpty {
          exploreSongs[a] = exploreReserve[a]
          exploreTotals[a] = exploreReserve[a].reduce(0) { $0 + candidates[$1].explore }
        }
      }
      while explorePicks.count < exploreQuota, exploreTotals.contains(where: { $0 > 0 }) {
        let means = exploreTotals.indices.map {
          exploreSongs[$0].isEmpty ? 0 : exploreTotals[$0] / Double(exploreSongs[$0].count)
        }
        let a = pickWeighted(means, rng: &rng)
        // Rounding can land the draw on a drained artist.
        guard !exploreSongs[a].isEmpty else {
          exploreTotals[a] = 0
          continue
        }
        let s = pickWeighted(exploreSongs[a].map { candidates[$0].explore }, rng: &rng)
        let n = exploreSongs[a].remove(at: s)
        exploreTotals[a] -= candidates[n].explore
        // A drained artist must read exactly zero: a float residue would
        // keep the loop alive with nothing left to draw.
        if exploreSongs[a].isEmpty { exploreTotals[a] = 0 }
        let taken = admit(n) == .taken
        if taken { explorePicks.append(n) }
        let artistKey = entries[candidates[n].index].artistKey
        let artistFull = artistCounts[artistKey, default: 0] >= cfg.perArtistCap
        if round == 0, taken || exploreSongs[a].isEmpty {
          exploreReserve[a] = exploreSongs[a]
          exploreSongs[a] = []
          exploreTotals[a] = 0
        } else if round == 1, taken || artistFull || exploreSongs[a].isEmpty {
          // No more draws on an artist the caps are closed for.
          exploreSongs[a] = []
          exploreTotals[a] = 0
        }
      }
    }

    // Preferred songs: weighted sampling without replacement (Efraimidis–
    // Spirakis: one random key per candidate, then key order; the weight
    // raised to the sampling exponent) over the best few per wanted song, a
    // few per artist so the caps rarely drain it; over the whole library its
    // long tail would outweigh the favourites. The rest follows by weight,
    // and then the caps give way.
    let ranked = candidates.indices.filter { candidates[$0].preferred > 0 }
      .sorted { candidates[$0].preferred > candidates[$1].preferred }
    var pool: [Int] = []
    var rest: [Int] = []
    var poolArtists: [String: Int] = [:]
    for n in ranked {
      let artist = entries[candidates[n].index].artistKey
      if bootstrap
        || (pool.count < cfg.preferredPoolFactor * count
          && poolArtists[artist, default: 0] < cfg.poolPerArtist)
      {
        pool.append(n)
        poolArtists[artist, default: 0] += 1
      } else {
        rest.append(n)
      }
    }
    let preferredOrder =
      pool.map { n in
        (
          n,
          log(Double.random(in: .leastNonzeroMagnitude..<1, using: &rng))
            / pow(candidates[n].preferred, cfg.preferredSamplingExponent)
        )
      }
      .sorted { $0.1 > $1.1 }
      .map(\.0) + rest
    notes.append("\(explorePool), quota \(exploreQuota), taken \(explorePicks.count)")
    let sampled = Set(pool)
    var sources: [Int: Source] = [:]
    var preferredPicks: [Int] = []
    for n in preferredOrder where preferredPicks.count + explorePicks.count < count {
      switch admit(n) {
      case .taken:
        preferredPicks.append(n)
        sources[n] = sampled.contains(n) ? .sampled : .remainder
      case .capped: overflow.append(n)
      case .rejected: break
      }
    }
    let capped = preferredPicks.count
    for relax in [Relax.genre, .all] {
      for n in overflow where preferredPicks.count + explorePicks.count < count {
        if admit(n, relax: relax) == .taken {
          preferredPicks.append(n)
          sources[n] = relax == .genre ? .relaxedGenre : .relaxedCaps
        }
      }
    }
    if preferredPicks.count > capped { notes.append("caps relaxed") }

    // Exploration lands on every ⌈n/k⌉-th position, preferred songs around it.
    let total = preferredPicks.count + explorePicks.count
    var exploreSlots = Set<Int>()
    if !explorePicks.isEmpty {
      let step = (total + explorePicks.count - 1) / explorePicks.count
      for e in 1...explorePicks.count { exploreSlots.insert(min(total - 1, e * step - 1)) }
    }
    var order: [(n: Int, slot: Slot)] = []
    var nextPreferred = preferredPicks.makeIterator()
    var nextExplore = explorePicks.makeIterator()
    for position in 0..<total {
      if exploreSlots.contains(position), let n = nextExplore.next() {
        order.append((n, .explore))
      } else if let n = nextPreferred.next() {
        order.append((n, .preferred))
      } else if let n = nextExplore.next() {
        order.append((n, .explore))
      }
    }
    order = Self.spreadArtists(order, after: seedArtist) {
      entries[candidates[$0.n].index].artistKey
    }

    let picks = order.map { item -> MixRecord.Pick in
      let c = candidates[item.n]
      let song = library[c.index]
      return MixRecord.Pick(
        slot: item.slot == .explore ? "explore" : "preferred", title: song.title,
        artist: song.artist,
        reason: reason(
          c, slot: item.slot, frequentArtist: artists[entries[c.index].artistKey]?.cluster ?? false,
          bootstrap: bootstrap),
        scores: scores(
          c, source: sources[item.n] ?? .explore, plays: lifetimePlays[c.index],
          keepPlaying: context != nil))
    }
    let record = MixRecord(
      at: now, mode: modeName, picks: picks,
      eligible: candidates.filter { $0.preferred > 0 }.count,
      exploreShare: total == 0 ? 0 : Double(explorePicks.count) / Double(total), notes: notes)
    return (order.map { library[candidates[$0.n].index] }, record)
  }

  /// Decayed skip load of one song: each skip weighs its q, halving every 14 days.
  func skipLoad(_ events: [JournalSnapshot.SkipEvent], now: Date) -> Double {
    events.reduce(0) {
      $0 + $1.weight * exp2(-max(0, now.timeIntervalSince($1.at)) / config.skipHalfLife)
    }
  }

  /// The song's penalty from its own skips.
  func skipPenalty(_ events: [JournalSnapshot.SkipEvent], now: Date) -> Double {
    config.skipPenalty * min(config.skipLoadCap, skipLoad(events, now: now))
  }

  // MARK: - Helpers

  /// f(x; k) = min(1, ln(1+x) / ln(1+k)).
  private func saturate(_ x: Double, _ k: Double) -> Double {
    min(1, log1p(max(0, x)) / log1p(k))
  }

  private func pickWeighted(_ weights: [Double], rng: inout some RandomNumberGenerator) -> Int {
    let total = weights.reduce(0, +)
    guard total > 0 else { return 0 }
    var roll = Double.random(in: 0..<total, using: &rng)
    for (i, weight) in weights.enumerated() {
      roll -= weight
      if roll < 0 { return i }
    }
    return weights.count - 1
  }

  /// Push apart back-to-back songs by the same artist where possible; the
  /// first song also moves away from `lead`, the artist that played last.
  static func spreadArtists<T>(_ items: [T], after lead: String?, artist: (T) -> String) -> [T] {
    var result = items
    for i in result.indices {
      guard let previous = i == 0 ? lead : artist(result[i - 1]), !previous.isEmpty,
        artist(result[i]) == previous
      else { continue }
      if let swap = ((i + 1)..<result.count).first(where: { artist(result[$0]) != previous }) {
        result.swapAt(i, swap)
      }
    }
    return result
  }

  private func reason(_ c: Candidate, slot: Slot, frequentArtist: Bool, bootstrap: Bool) -> String {
    if slot == .explore {
      return frequentArtist
        ? "less-played track by a frequent artist" : "less-played track in a favourite genre"
    }
    var parts: [String] = []
    let rated = c.rating == 5 ? "boosted" : c.rating == 4 ? "rated 4" : nil
    if let rated {
      parts.append(c.ratingSource == .song ? rated : "\(c.ratingSource.rawValue) \(rated)")
    }
    if c.starred { parts.append("liked") }
    if c.likedAlbum {
      parts.append("liked album")
    } else if c.likedArtist {
      parts.append("liked artist")
    }
    if c.song >= 0.5 { parts.append("favourite") }
    if c.seedArtist {
      parts.append("same artist as before")
    } else if c.anchored {
      parts.append("fits the session's genres")
    }
    if c.artist >= 0.5 {
      parts.append("high artist affinity")
    } else if c.genre >= 0.5 {
      parts.append("favourite genre")
    }
    if bootstrap { parts.append("bootstrap") }
    return parts.isEmpty ? "steady pick" : parts.prefix(3).joined(separator: ", ")
  }

  private func ratingBonus(_ rating: Int) -> Double {
    rating == 5 ? config.boostBonus : rating == 4 ? config.ratedFourBonus : 0
  }

  private func ratingMultiplier(_ rating: Int) -> Double {
    rating == 2 ? config.ratedTwoMultiplier : 1
  }

  /// The terms of the pick's weight. A preferred song's are its weighted
  /// contributions (`final` = cool × rating multiplier × their sum with the
  /// base weight); an explore song's are the features its weight grows and
  /// shrinks with.
  private func scores(_ c: Candidate, source: Source, plays: Int, keepPlaying: Bool) -> String {
    func f(_ x: Double) -> String {
      let text = String(format: "%.2f", x)
      if text.hasPrefix("0.") { return String(text.dropFirst()) }
      if text.hasPrefix("-0.") { return "-" + text.dropFirst(2) }
      return text
    }
    let cfg = config
    let rating =
      "rating=\(c.rating)" + (c.ratingSource == .song ? "" : "(\(c.ratingSource.rawValue))")
    var text = "src=\(source.rawValue) "
    if source == .explore {
      text +=
        "artist=\(f(c.artist)) genre=\(f(c.genre)) plays=\(plays) \(rating) "
        + "skip=\(f(-c.skip)) press=\(f(-c.pressure))"
    } else {
      let ratingTerm =
        c.rating == 2 ? "x" + f(ratingMultiplier(c.rating)) : "+" + f(ratingBonus(c.rating))
      text +=
        "artist=\(f(cfg.artistWeight * c.artist)) album=\(f(cfg.albumWeight * c.album)) "
        + "genre=\(f(cfg.genreWeight * c.genre)) era=\(f(cfg.eraWeight * c.era)) "
        + "song=\(f(cfg.songWeight * c.song)) star=\(f(c.starred ? cfg.starWeight : 0)) "
        + "coll=\(f(c.collection)) \(rating)\(ratingTerm) skip=\(f(-c.skip)) "
        + "press=\(f(-c.pressure))"
    }
    if keepPlaying { text += " ctx=\(f(c.context))" }
    return text + " cool=\(f(c.cool)) final=\(f(source == .explore ? c.explore : c.preferred))"
  }

  /// The listening history's artist aggregates, stored per server artist,
  /// summed per artist key: spellings of one artist share their plays.
  static func artistAffinity(
    _ stored: [String: AffinitySnapshot.Aggregate], index: SmartPlaybackService.LibraryIndex
  ) -> [String: AffinitySnapshot.Aggregate] {
    stored.reduce(into: [:]) { groups, row in
      let key = index.artistKeys[row.key] ?? row.key
      guard let group = groups[key] else {
        groups[key] = row.value
        return
      }
      groups[key] = AffinitySnapshot.Aggregate(
        weight: group.weight + row.value.weight,
        lastPlayAt: [group.lastPlayAt, row.value.lastPlayAt].compactMap { $0 }.max(),
        plays: group.plays + row.value.plays)
    }
  }
}

/// Small seedable generator, so a DEBUG seed repeats a mix exactly.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
