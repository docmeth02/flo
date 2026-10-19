//
//  MixRanker.swift
//  flo
//

import Foundation

/// Scores the library for one mix and samples it: mostly preferred songs by
/// affinity, ratings and stars, plus a share of lesser-played songs from the
/// listener's own artists and genres. Pure and synchronous: every input is a
/// snapshot, so the same inputs and generator state give the same mix.
struct MixRanker {
  struct Config {
    // Saturation points of the affinity features: f(x; k) reaches 1 at x = k.
    let artistK = 40.0
    let albumK = 15.0
    let genreK = 80.0
    let eraK = 120.0
    let songK = 8.0
    /// Server play counts above this add nothing to a song's prior.
    let priorPlayCap = 10
    /// Decayed history at which the log is trusted fully over server counts.
    let fullTrustWeight = 40.0
    /// Trust in the log while its import has not reached the oldest play.
    let partialImportTrust = 0.5
    /// Below this much decayed history the mix starts cold.
    let coldStartWeight = 20.0

    let baseWeight = 0.02
    let artistWeight = 0.24
    let albumWeight = 0.10
    let genreWeight = 0.16
    let eraWeight = 0.04
    let songWeight = 0.16
    let starWeight = 0.25
    let boostBonus = 0.35
    let ratedFourBonus = 0.20
    let ratedTwoMultiplier = 0.02
    /// Added for a song on a liked album or by a liked artist, together at
    /// most `collectionBonusCap`.
    let likedAlbumBonus = 0.10
    let likedArtistBonus = 0.08
    let collectionBonusCap = 0.15

    let skipHalfLife: TimeInterval = 14 * 86400
    let skipPenalty = 0.15
    let skipLoadCap = 2.0
    let artistSkipPenalty = 0.05
    let artistSkipMinSongs = 3
    let artistSkipDamping = 5.0

    let cooldownFloor = 0.05
    let cooldownHours = 6.0
    let titleCooldownFloor = 0.10
    let titleCooldownHours = 2.0
    /// Title siblings heard longer ago than this are fully cooled down.
    let titleCooldownWindow: TimeInterval = 24 * 3600

    let clusterArtistWeight = 3.0
    let clusterGenreWeight = 8.0
    let clusterGenreArtists = 3
    let exploreBase = 0.25
    let exploreMaxPlays = 2

    let playSomethingExplore = 1.0 / 6
    let keepPlayingExplore = 1.0 / 3
    let keepPlayingExploreMax = 0.40
    let keepPlayingRampMinutes = 90.0

    /// Preferred songs are sampled from this many candidates per wanted song.
    let preferredPoolFactor = 5
    /// Sampling weighs a preferred song by its weight to this power, so
    /// favourites stand out of a long tail of weak songs. Settable for the
    /// test that compares it with linear sampling.
    var preferredSamplingExponent = 2.0
    let poolPerArtist = 4

    let perArtistCap = 2
    let perAlbumCap = 2
    let genreCeiling = 0.60

    let anchorGenreBonus = 0.15
    let seedArtistBonus = 0.15
    let seedAlbumPenalty = 0.12
    /// Anchor genres bound the candidates while this many per wanted song remain.
    let anchorMinFactor = 3
  }

  let config: Config

  init(config: Config = Config()) {
    self.config = config
  }

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

  /// Which caps a refill may step over.
  private enum Relax { case none, genre, all }

  private typealias Entry = SmartPlaybackService.LibraryIndex.Entry

  /// The snapshots one ranking works from, as `rank` takes them.
  private struct Input {
    let library: [Song]
    let index: SmartPlaybackService.LibraryIndex
    let affinity: AffinitySnapshot
    let journal: JournalSnapshot
    let pendingPlays: [String: Date]
    let recentPlays: [String: Int]
    let ratings: [String: Rating]
    let starred: Set<String>
    let likedAlbums: Set<String>
    let likedArtists: Set<String>
    let context: SmartPlaybackService.KeepPlayingContext?
    let count: Int
    let now: Date
  }

  /// What the first pass over the library learns: each song's keys, plays
  /// and latest listen, and the server's counts summed into priors.
  private struct Scan {
    let ids: [String]
    let entries: [Entry]
    let titles: Titles
    /// The decayed history of all songs, and how far it is trusted over the
    /// server's play counts.
    let totalWeight: Double
    let trust: Double
    let artists: [String: ArtistStats]
    let albumPrior: [String: Double]
    let genrePrior: [String: Double]
    let eraPrior: [String: Double]
    /// The artists with history in each genre.
    let genreArtists: [String: Set<String>]
    /// Liked artists and those of songs rated up or liked.
    let favouredArtists: Set<String>
    /// Artist keys of the folded names the skips and the seed give.
    let artistIds: [String: String]
    let seedArtist: String?
    let lifetimePlays: [Int]
    let songWeights: [Double]
    let heardAt: [Date?]
  }

  /// What the scoring knows of the artists, albums, genres and eras.
  private struct Standing {
    let artists: [String: ArtistStats]
    let albumFeature: [String: Double]
    let eraFeature: [String: Double]
    let genres: [String: (feature: Double, cluster: Bool)]
    /// Skip load per song.
    let songSkip: [String: Double]
  }

  // MARK: - Ranking

  /// `pendingPlays` are the latest listens per song still in the outbox: the
  /// server's log has not counted them yet, so they only cool their songs
  /// down, like the journal's. `likedAlbums` are album ids, `likedArtists`
  /// artist keys. `recentPlays` are the mirrored plays per song of the last
  /// 60 days; they only word the picks' reasons.
  func rank(
    library: [Song], index: SmartPlaybackService.LibraryIndex, affinity: AffinitySnapshot,
    journal: JournalSnapshot, pendingPlays: [String: Date], recentPlays: [String: Int] = [:],
    ratings: [String: Rating],
    starred: Set<String>, likedAlbums: Set<String>, likedArtists: Set<String>,
    mode: SmartPlaybackService.MixMode, count: Int, now: Date,
    rng: inout some RandomNumberGenerator
  ) -> (songs: [Song], record: MixRecord) {
    var context: SmartPlaybackService.KeepPlayingContext?
    if case .keepPlaying(let keep) = mode { context = keep }
    let input = Input(
      library: library, index: index, affinity: affinity, journal: journal,
      pendingPlays: pendingPlays, recentPlays: recentPlays, ratings: ratings, starred: starred,
      likedAlbums: likedAlbums, likedArtists: likedArtists, context: context, count: count,
      now: now)
    var notes: [String] = []

    let scan = scanLibrary(input)
    let standing = weigh(scan, input)
    var candidates = score(input, scan, standing)
    if let note = boundByAnchorGenres(&candidates, input, scan) { notes.append(note) }
    var bootstrap = false
    if scan.totalWeight < config.coldStartWeight {
      let start = startCold(&candidates, input, scan)
      bootstrap = start.bootstrap
      notes.append(start.note)
    }

    let quota = exploreQuota(input, rng: &rng)
    var selection = Selection(candidates, scan, input, config: config)
    let explore = sampleExplore(candidates, scan, quota: quota, into: &selection, rng: &rng)
    notes.append(explore.note)
    let preferred = samplePreferred(
      candidates, scan, count: count, room: count - explore.picks.count, bootstrap: bootstrap,
      into: &selection, rng: &rng)
    if preferred.relaxed { notes.append("caps relaxed") }

    let order = arrange(preferred: preferred.picks, explore: explore.picks, candidates, scan)
    let picks = describe(
      order, candidates, input, scan, standing, sources: preferred.sources, bootstrap: bootstrap)
    let record = MixRecord(
      at: now, mode: context == nil ? "playSomething" : "keepPlaying", picks: picks,
      eligible: candidates.filter { $0.preferred > 0 }.count,
      exploreShare: order.isEmpty ? 0 : Double(explore.picks.count) / Double(order.count),
      notes: notes)
    return (order.map { library[candidates[$0.n].index] }, record)
  }

  /// Decayed skip load of one song: each skip weighs its q, halving every 14 days.
  func skipLoad(_ events: [JournalSnapshot.SkipEvent], now: Date) -> Double {
    events.reduce(0) {
      $0 + $1.weight * exp2(-max(0, now.timeIntervalSince($1.at)) / config.skipHalfLife)
    }
  }

  // MARK: - Passes

  /// Pass 1: keys, server-count priors, catalogue plays and title cooldowns.
  private func scanLibrary(_ input: Input) -> Scan {
    let cfg = config
    let library = input.library
    let now = input.now
    let songAgg = input.affinity.aggregates[.song] ?? [:]

    // How far the log is trusted over the server's play counts.
    let totalWeight = songAgg.values.reduce(0) { $0 + $1.weight }
    var trust = min(1, totalWeight / cfg.fullTrustWeight)
    if !input.affinity.state.bootstrapComplete { trust = min(trust, cfg.partialImportTrust) }

    // Skips and the seed name artists; the library maps names to artist keys.
    var wantedNames = Set<String>()
    if let context = input.context,
      let name = ArtistIdentity.key(name: context.seed.artist, mbid: nil)
    {
      wantedNames.insert(name)
    }
    for (id, events) in input.journal.skips where input.index.songs[id] == nil {
      wantedNames.formUnion(events.map(\.artistKey))
    }
    wantedNames.remove("")

    let ids = library.map(\.playbackID)
    let entries = library.indices.map {
      input.index.songs[ids[$0]] ?? Entry(library[$0], artistKeys: input.index.artistKeys)
    }
    let titles = Titles(library: library, entries: entries)
    var artists: [String: ArtistStats] = [:]
    var albumPrior: [String: Double] = [:]
    var genrePrior: [String: Double] = [:]
    var eraPrior: [String: Double] = [:]
    var artistIds: [String: String] = [:]
    var foldedNames: [String: String] = [:]
    var genreArtists: [String: Set<String>] = [:]
    var favouredArtists = input.likedArtists
    var lifetimePlays = [Int](repeating: 0, count: library.count)
    var songWeights = [Double](repeating: 0, count: library.count)
    var heardAt = [Date?](repeating: nil, count: library.count)

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

      let rating = input.ratings[ids[i]]?.stars ?? 0
      if rating >= 4 || input.starred.contains(ids[i]) { favouredArtists.insert(entry.artistKey) }

      if !wantedNames.isEmpty {
        // Folding is slow; a library repeats few artist spellings.
        let name =
          foldedNames[song.artist] ?? ArtistIdentity.key(name: song.artist, mbid: nil) ?? ""
        foldedNames[song.artist] = name
        if wantedNames.contains(name), artistIds[name] == nil { artistIds[name] = entry.artistKey }
      }

      // Each source of a play cools it down once: the latest of them counts.
      let heard =
        [aggregate?.lastPlayAt, input.journal.lastHeardAt[ids[i]], input.pendingPlays[ids[i]]]
        .compactMap { $0 }.max()
      heardAt[i] = heard
      if let heard, now.timeIntervalSince(heard) < cfg.titleCooldownWindow {
        titles.noteHeard(i, at: heard)
      }
    }

    let seedArtist = input.context.map {
      let name = ArtistIdentity.key(name: $0.seed.artist, mbid: nil) ?? ""
      return artistIds[name] ?? name
    }
    return Scan(
      ids: ids, entries: entries, titles: titles, totalWeight: totalWeight, trust: trust,
      artists: artists, albumPrior: albumPrior, genrePrior: genrePrior, eraPrior: eraPrior,
      genreArtists: genreArtists, favouredArtists: favouredArtists, artistIds: artistIds,
      seedArtist: seedArtist, lifetimePlays: lifetimePlays, songWeights: songWeights,
      heardAt: heardAt)
  }

  /// Skip load per song, and per artist the songs skipped and their load,
  /// each song adding at most 1.
  private func weighSkips(_ input: Input, _ scan: Scan) -> (
    songs: [String: Double], artists: [String: (songs: Int, load: Double)]
  ) {
    var songs: [String: Double] = [:]
    var artists: [String: (songs: Int, load: Double)] = [:]
    for (id, events) in input.journal.skips {
      let load = skipLoad(events, now: input.now)
      songs[id] = load
      let name = events.first?.artistKey ?? ""
      let artist = input.index.songs[id]?.artistKey ?? scan.artistIds[name] ?? name
      guard !artist.isEmpty else { continue }
      artists[artist, default: (0, 0)].songs += 1
      artists[artist, default: (0, 0)].load += min(1, load)
    }
    return (songs, artists)
  }

  /// Features blend the log with the server's counts, once per key.
  /// Clusters: artists played a fair amount, liked or with a favoured song,
  /// and genres played a fair amount across several artists.
  private func weigh(_ scan: Scan, _ input: Input) -> Standing {
    let cfg = config
    let artistAgg = Self.artistAffinity(
      input.affinity.aggregates[.artist] ?? [:], index: input.index)
    let genreAgg = input.affinity.aggregates[.genre] ?? [:]
    let skips = weighSkips(input, scan)

    func features(_ kind: AffinitySnapshot.Kind, _ priors: [String: Double], _ k: Double)
      -> [String: Double]
    {
      let aggregates = input.affinity.aggregates[kind] ?? [:]
      return priors.reduce(into: [:]) {
        $0[$1.key] = feature(aggregates[$1.key]?.weight, $1.value, k, trust: scan.trust)
      }
    }

    var artists = scan.artists
    for (key, var artist) in artists {
      let weight = artistAgg[key]?.weight
      artist.feature = feature(weight, artist.prior, cfg.artistK, trust: scan.trust)
      artist.cluster =
        (weight ?? 0) >= cfg.clusterArtistWeight || scan.favouredArtists.contains(key)
      if artist.plays.count >= 2 {
        artist.lowerHalf = artist.plays.sorted()[artist.plays.count / 2 - 1]
      }
      // Skips press on an artist once several of its songs were skipped; its
      // decayed affinity weight (the snapshot's, 60-day half-life) dampens
      // the pressure, so an artist played a lot shrugs off a few skips.
      if let skipped = skips.artists[key], skipped.songs >= cfg.artistSkipMinSongs {
        artist.pressure =
          cfg.artistSkipPenalty * skipped.load
          / (skipped.load + (weight ?? 0) + cfg.artistSkipDamping)
      }
      artists[key] = artist
    }
    let genres = scan.genrePrior.reduce(into: [String: (feature: Double, cluster: Bool)]()) {
      let weight = genreAgg[$1.key]?.weight ?? 0
      $0[$1.key] = (
        feature(weight, $1.value, cfg.genreK, trust: scan.trust),
        weight >= cfg.clusterGenreWeight
          && (scan.genreArtists[$1.key]?.count ?? 0) >= cfg.clusterGenreArtists
      )
    }
    return Standing(
      artists: artists, albumFeature: features(.album, scan.albumPrior, cfg.albumK),
      eraFeature: features(.era, scan.eraPrior, cfg.eraK), genres: genres,
      songSkip: skips.songs)
  }

  /// Pass 2: features, cooldowns and the weights of both pools. Songs rated
  /// down and songs already queued drop out.
  private func score(_ input: Input, _ scan: Scan, _ standing: Standing) -> [Candidate] {
    let cfg = config
    let library = input.library
    let queueIds = input.context?.queueIds ?? []
    var candidates: [Candidate] = []
    candidates.reserveCapacity(library.count)
    for i in library.indices {
      let song = library[i]
      let entry = scan.entries[i]
      let id = scan.ids[i]
      // Lookups in empty dictionaries still hash, and most of these are empty.
      let rated = input.ratings.isEmpty ? nil : input.ratings[id]
      let rating = rated?.stars ?? 0
      if rating == 1 || (!queueIds.isEmpty && (queueIds.contains(song.id) || queueIds.contains(id)))
      {
        continue
      }

      var c = Candidate(index: i)
      let artist = standing.artists[entry.artistKey] ?? ArtistStats()
      // A liked album's own songs count as a cluster.
      var inCluster = artist.cluster || input.likedAlbums.contains(entry.albumId)
      c.artist = artist.feature
      c.album = standing.albumFeature[entry.albumId] ?? 0
      for genre in entry.genres {
        guard let stats = standing.genres[genre] else { continue }
        c.genre = max(c.genre, stats.feature)
        inCluster = inCluster || stats.cluster
      }
      c.era = entry.era.flatMap { standing.eraFeature[$0] } ?? 0
      c.song = feature(
        scan.songWeights[i], Double(min(song.playCount ?? 0, cfg.priorPlayCap)), cfg.songK,
        trust: scan.trust)
      c.rating = rating
      c.ratingSource = rated?.source ?? .song
      c.starred = !input.starred.isEmpty && input.starred.contains(id)
      c.likedAlbum = !input.likedAlbums.isEmpty && input.likedAlbums.contains(entry.albumId)
      c.likedArtist = !input.likedArtists.isEmpty && input.likedArtists.contains(entry.artistKey)
      c.collection = min(
        cfg.collectionBonusCap,
        (c.likedAlbum ? cfg.likedAlbumBonus : 0) + (c.likedArtist ? cfg.likedArtistBonus : 0))
      c.skip =
        standing.songSkip.isEmpty
        ? 0 : cfg.skipPenalty * min(cfg.skipLoadCap, standing.songSkip[id] ?? 0)
      c.pressure = artist.pressure
      c.cool = cool(i, scan, now: input.now)

      if let context = input.context {
        c.anchored = entry.genres.contains { context.anchorGenres.contains($0) }
        c.seedArtist = !entry.artistKey.isEmpty && entry.artistKey == scan.seedArtist
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
      let plays = scan.lifetimePlays[i]
      let lessPlayed = plays <= cfg.exploreMaxPlays || artist.lowerHalf.map { plays <= $0 } ?? false
      if inCluster, lessPlayed, rating == 0 || rating >= 3 {
        c.explore =
          c.cool
          * max(0, cfg.exploreBase + c.artist + c.genre + max(0, c.context) - c.skip - c.pressure)
          / (1 + Double(plays)).squareRoot()
      }
      candidates.append(c)
    }
    return candidates
  }

  /// How far a song is cooled down by its own latest listen and by a title
  /// sibling's.
  private func cool(_ i: Int, _ scan: Scan, now: Date) -> Double {
    let cfg = config
    var cool = 1.0
    if let heard = scan.heardAt[i] {
      let hours = max(0, now.timeIntervalSince(heard)) / 3600
      cool = cfg.cooldownFloor + (1 - cfg.cooldownFloor) * (1 - exp(-hours / cfg.cooldownHours))
    }
    if let heard = scan.titles.siblingHeardAt(i) {
      let hours = max(0, now.timeIntervalSince(heard)) / 3600
      cool = min(
        cool,
        cfg.titleCooldownFloor + (1 - cfg.titleCooldownFloor)
          * (1 - exp(-hours / cfg.titleCooldownHours)))
    }
    return cool
  }

  /// The session's genres bound a continuation while enough songs share
  /// them, by enough artists to fill the mix within the artist cap. Returns
  /// the note on them; nil without anchor genres.
  private func boundByAnchorGenres(
    _ candidates: inout [Candidate], _ input: Input, _ scan: Scan
  ) -> String? {
    guard let anchorGenres = input.context?.anchorGenres, !anchorGenres.isEmpty else {
      return nil
    }
    let anchored = candidates.filter(\.anchored)
    var perArtist: [String: Int] = [:]
    for c in anchored { perArtist[scan.entries[c.index].artistKey, default: 0] += 1 }
    let fillable = perArtist.values.reduce(0) { $0 + min($1, config.perArtistCap) }
    let genres = anchorGenres.sorted().joined(separator: ", ")
    guard anchored.count >= config.anchorMinFactor * input.count, fillable >= input.count else {
      return
        "anchor genres: \(genres) (\(anchored.count) songs by \(perArtist.count) artists, "
        + "not bounding)"
    }
    candidates = anchored
    return "anchor genres: \(genres)"
  }

  /// Cold start: anchor on ratings and stars, else on the server's counts,
  /// widened to their artists and then their genres; with neither, every
  /// artist is equally likely. Returns whether it is that bootstrap, and the
  /// note on it.
  private func startCold(
    _ candidates: inout [Candidate], _ input: Input, _ scan: Scan
  ) -> (bootstrap: Bool, note: String) {
    let entries = scan.entries
    let enough = config.anchorMinFactor * input.count
    let favoured = candidates.filter { $0.rating >= 4 || $0.starred || $0.collection > 0 }
    let counted = candidates.filter { scan.lifetimePlays[$0.index] > 0 }
    let seeds = favoured.isEmpty ? counted : favoured
    guard !seeds.isEmpty else {
      for n in candidates.indices {
        let artist = entries[candidates[n].index].artistKey
        candidates[n].preferred /= Double(max(1, scan.artists[artist]?.songs ?? 1))
      }
      return (true, "bootstrap")
    }
    let seedArtists = Set(seeds.map { entries[$0.index].artistKey })
    let seedGenres = Set(seeds.flatMap { entries[$0.index].genres })
    var keep: (Candidate) -> Bool = { seedArtists.contains(entries[$0.index].artistKey) }
    var widened = "artists"
    if candidates.filter(keep).count < enough {
      keep = { !seedGenres.isDisjoint(with: entries[$0.index].genres) }
      widened = "genres"
      if candidates.filter(keep).count < enough {
        keep = { _ in true }
        widened = "library"
      }
    }
    for n in candidates.indices where !keep(candidates[n]) { candidates[n].preferred = 0 }
    return (
      false, "cold start: \(favoured.isEmpty ? "server counts" : "ratings/stars"), their \(widened)"
    )
  }

  /// Exploration quota: a fixed share for Play Something, growing with the
  /// session for Keep Playing; the fraction is rounded at random.
  private func exploreQuota(_ input: Input, rng: inout some RandomNumberGenerator) -> Int {
    let cfg = config
    let share =
      input.context.map {
        cfg.keepPlayingExplore + (cfg.keepPlayingExploreMax - cfg.keepPlayingExplore)
          * min(max(0, $0.sessionMinutes) / cfg.keepPlayingRampMinutes, 1)
      } ?? cfg.playSomethingExplore
    let wanted = Double(input.count) * share
    return Int(wanted)
      + (Double.random(in: 0..<1, using: &rng) < wanted - wanted.rounded(.down) ? 1 : 0)
  }

  /// Exploration goes first, so its share survives the caps: an artist by
  /// the mean weight of its songs left, so a large catalogue does not
  /// crowd out a small one, then one of the artist's songs. Returns the
  /// picks and the note on the pool.
  private func sampleExplore(
    _ candidates: [Candidate], _ scan: Scan, quota: Int, into selection: inout Selection,
    rng: inout some RandomNumberGenerator
  ) -> (picks: [Int], note: String) {
    var exploreSongs: [[Int]] = []
    var exploreTotals: [Double] = []
    var exploreSlot: [String: Int] = [:]
    for n in candidates.indices where candidates[n].explore > 0 {
      let artist = scan.entries[candidates[n].index].artistKey
      if exploreSlot[artist] == nil {
        exploreSlot[artist] = exploreSongs.count
        exploreSongs.append([])
        exploreTotals.append(0)
      }
      let a = exploreSlot[artist]!
      exploreSongs[a].append(n)
      exploreTotals[a] += candidates[n].explore
    }
    let pool =
      "explore pool: \(exploreSongs.reduce(0) { $0 + $1.count }) songs by "
      + "\(exploreSongs.count) artists"
    var picks: [Int] = []
    // One discovery per artist leaves the favourites room in the caps; the
    // artists' remaining songs are kept for a second round in case the
    // quota is not met with one each.
    var exploreReserve: [[Int]] = Array(repeating: [], count: exploreSongs.count)
    for round in 0..<2 {
      if round == 1 {
        guard picks.count < quota else { break }
        for a in exploreReserve.indices where !exploreReserve[a].isEmpty {
          exploreSongs[a] = exploreReserve[a]
          exploreTotals[a] = exploreReserve[a].reduce(0) { $0 + candidates[$1].explore }
        }
      }
      while picks.count < quota, exploreTotals.contains(where: { $0 > 0 }) {
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
        let taken = selection.admit(n) == .taken
        if taken { picks.append(n) }
        let artistFull = selection.isFull(artist: scan.entries[candidates[n].index].artistKey)
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
    return (picks, "\(pool), quota \(quota), taken \(picks.count)")
  }

  /// Preferred songs: weighted sampling without replacement (Efraimidis–
  /// Spirakis: one random key per candidate, then key order; the weight
  /// raised to the sampling exponent) over the best few per wanted song, a
  /// few per artist so the caps rarely drain it; over the whole library its
  /// long tail would outweigh the favourites. The rest follows by weight,
  /// and then the caps give way. `room` is what exploration left of
  /// `count`. Returns the picks, how each got in and whether caps gave way.
  private func samplePreferred(
    _ candidates: [Candidate], _ scan: Scan, count: Int, room: Int, bootstrap: Bool,
    into selection: inout Selection, rng: inout some RandomNumberGenerator
  ) -> (picks: [Int], sources: [Int: Source], relaxed: Bool) {
    let cfg = config
    let ranked = candidates.indices.filter { candidates[$0].preferred > 0 }
      .sorted { candidates[$0].preferred > candidates[$1].preferred }
    var pool: [Int] = []
    var rest: [Int] = []
    var poolArtists: [String: Int] = [:]
    for n in ranked {
      let artist = scan.entries[candidates[n].index].artistKey
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
    // Bootstrap weights are already divided by the artist's song count;
    // squaring them would favour small catalogues.
    let exponent = bootstrap ? 1 : cfg.preferredSamplingExponent
    let order =
      pool.map { n in
        (
          n,
          log(Double.random(in: .leastNonzeroMagnitude..<1, using: &rng))
            / pow(candidates[n].preferred, exponent)
        )
      }
      .sorted { $0.1 > $1.1 }
      .map(\.0) + rest
    let sampled = Set(pool)
    var sources: [Int: Source] = [:]
    var picks: [Int] = []
    // A capped song waits in the overflow for a refill.
    var overflow: [Int] = []
    for n in order where picks.count < room {
      switch selection.admit(n) {
      case .taken:
        picks.append(n)
        sources[n] = sampled.contains(n) ? .sampled : .remainder
      case .capped: overflow.append(n)
      case .rejected: break
      }
    }
    let capped = picks.count
    for relax in [Relax.genre, .all] {
      for n in overflow where picks.count < room {
        if selection.admit(n, relax: relax) == .taken {
          picks.append(n)
          sources[n] = relax == .genre ? .relaxedGenre : .relaxedCaps
        }
      }
    }
    return (picks, sources, picks.count > capped)
  }

  /// Exploration lands on every ⌈n/k⌉-th position, preferred songs around
  /// it; then songs by one artist move apart.
  private func arrange(
    preferred: [Int], explore: [Int], _ candidates: [Candidate], _ scan: Scan
  ) -> [(n: Int, slot: Slot)] {
    let total = preferred.count + explore.count
    var exploreSlots = Set<Int>()
    if !explore.isEmpty {
      let step = (total + explore.count - 1) / explore.count
      for e in 1...explore.count { exploreSlots.insert(min(total - 1, e * step - 1)) }
    }
    var order: [(n: Int, slot: Slot)] = []
    var nextPreferred = preferred.makeIterator()
    var nextExplore = explore.makeIterator()
    for position in 0..<total {
      if exploreSlots.contains(position), let n = nextExplore.next() {
        order.append((n, .explore))
      } else if let n = nextPreferred.next() {
        order.append((n, .preferred))
      } else if let n = nextExplore.next() {
        order.append((n, .explore))
      }
    }
    return Self.spreadArtists(order, after: scan.seedArtist) {
      scan.entries[candidates[$0.n].index].artistKey
    }
  }

  /// Each pick with why it is in the mix: in words for the listener, and as
  /// a reason and scores for diagnostics.
  private func describe(
    _ order: [(n: Int, slot: Slot)], _ candidates: [Candidate], _ input: Input, _ scan: Scan,
    _ standing: Standing, sources: [Int: Source], bootstrap: Bool
  ) -> [MixRecord.Pick] {
    // Over the whole index: offline the candidates are only the songs on the
    // device. Ties go to the lower key, so the same inputs word the same reasons.
    var artistRecentPlays: [String: Int] = [:]
    for (id, plays) in input.recentPlays {
      if let key = input.index.songs[id]?.artistKey { artistRecentPlays[key, default: 0] += plays }
    }
    let topArtist = artistRecentPlays.filter { !$0.key.isEmpty && $0.value > 0 }
      .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    return order.map { item -> MixRecord.Pick in
      let c = candidates[item.n]
      let song = input.library[c.index]
      let artistKey = scan.entries[c.index].artistKey
      let why = MixReason.make(
        MixReason.Facts(
          explore: item.slot == .explore, rating: c.rating, ratingSource: c.ratingSource,
          starred: c.starred, likedAlbum: c.likedAlbum, likedArtist: c.likedArtist,
          seedArtist: c.seedArtist, anchored: c.anchored,
          songPlays: input.recentPlays[scan.ids[c.index]] ?? 0,
          artistPlays: artistRecentPlays[artistKey] ?? 0, topArtist: artistKey == topArtist,
          lifetimePlays: scan.lifetimePlays[c.index], artist: song.artist, album: song.albumName,
          lastHeard: scan.heardAt[c.index], now: input.now))
      return MixRecord.Pick(
        slot: item.slot == .explore ? "explore" : "preferred", songId: scan.ids[c.index],
        title: song.title, artist: song.artist, why: why,
        reason: reason(
          c, slot: item.slot, frequentArtist: standing.artists[artistKey]?.cluster ?? false,
          bootstrap: bootstrap),
        scores: scores(
          c, source: sources[item.n] ?? .explore, plays: scan.lifetimePlays[c.index],
          keepPlaying: input.context != nil))
    }
  }

  // MARK: - Helpers

  /// f(x; k) = min(1, ln(1+x) / ln(1+k)).
  private func saturate(_ x: Double, _ k: Double) -> Double {
    min(1, log1p(max(0, x)) / log1p(k))
  }

  /// A feature blends the log with the server's counts by the log's trust.
  private func feature(_ weight: Double?, _ prior: Double, _ k: Double, trust: Double) -> Double {
    trust * saturate(weight ?? 0, k) + (1 - trust) * saturate(prior, k)
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

  // MARK: - Working state

  /// Title keys, "artist key|normalized title", each built once and only
  /// when needed, since normalizing is slow; and the titles heard within the
  /// cooldown window.
  private final class Titles {
    private let library: [Song]
    private let entries: [Entry]
    private var keys: [Int: String] = [:]
    private var recent: [String: Date] = [:]
    private var recentArtists = Set<String>()
    private var recentStarts = Set<String>()

    init(library: [Song], entries: [Entry]) {
      self.library = library
      self.entries = entries
    }

    func key(_ i: Int) -> String {
      if let key = keys[i] { return key }
      let key = entries[i].artistKey + "|" + SmartPlaybackService.normalizeTitle(library[i].title)
      keys[i] = key
      return key
    }

    func noteHeard(_ i: Int, at heard: Date) {
      let key = self.key(i)
      let artistKey = entries[i].artistKey
      guard let first = key.dropFirst(artistKey.count + 1).first else { return }
      recent[key] = max(recent[key] ?? heard, heard)
      recentArtists.insert(artistKey)
      recentStarts.insert(artistKey + "|" + String(first))
    }

    /// When a song of the same title by the same artist was heard last
    /// within the window, the song itself included.
    func siblingHeardAt(_ i: Int) -> Date? {
      guard !recent.isEmpty, mayShare(i) else { return nil }
      return recent[key(i)]
    }

    // Normalizing keeps a title's first character unless it opens with a
    // bracket or a space; anything else starting differently cannot be a
    // sibling of a recent title, and skips the slow normalization.
    private func mayShare(_ i: Int) -> Bool {
      guard recentArtists.contains(entries[i].artistKey),
        let first = library[i].title.first.map({ $0.lowercased() })
      else { return false }
      return first == "(" || first == "[" || first.allSatisfy(\.isWhitespace)
        || recentStarts.contains(entries[i].artistKey + "|" + first)
    }
  }

  /// The mix as it fills, with caps per artist and album and for Play
  /// Something a soft ceiling per genre. The genre ceiling gives way first;
  /// the artist and album caps only when the mix cannot be filled otherwise.
  private struct Selection {
    private let candidates: [Candidate]
    private let entries: [Entry]
    private let titles: Titles
    private let config: Config
    private let genreLimit: Int
    private var chosen = Set<Int>()
    private var titleKeys = Set<String>()
    private var artistCounts: [String: Int] = [:]
    private var albumCounts: [String: Int] = [:]
    private var genreCounts: [String: Int] = [:]

    init(_ candidates: [Candidate], _ scan: Scan, _ input: Input, config: Config) {
      self.candidates = candidates
      entries = scan.entries
      titles = scan.titles
      self.config = config
      genreLimit =
        input.context == nil
        ? Int((Double(input.count) * config.genreCeiling).rounded(.up)) : input.count
    }

    func isFull(artist: String) -> Bool {
      artistCounts[artist, default: 0] >= config.perArtistCap
    }

    mutating func admit(_ n: Int, relax: Relax = .none) -> Admission {
      let i = candidates[n].index
      let entry = entries[i]
      guard !chosen.contains(n), !titleKeys.contains(titles.key(i)) else { return .rejected }
      if relax != .all, !fits(n, relax) { return .capped }
      let genre = entry.genres.first
      chosen.insert(n)
      titleKeys.insert(titles.key(i))
      artistCounts[entry.artistKey, default: 0] += 1
      albumCounts[entry.albumId, default: 0] += 1
      if let genre { genreCounts[genre, default: 0] += 1 }
      return .taken
    }

    private func fits(_ n: Int, _ relax: Relax) -> Bool {
      let entry = entries[candidates[n].index]
      return artistCounts[entry.artistKey, default: 0] < config.perArtistCap
        && (entry.albumId.isEmpty || albumCounts[entry.albumId, default: 0] < config.perAlbumCap)
        && (relax == .genre
          || entry.genres.first.map { genreCounts[$0, default: 0] < genreLimit } ?? true)
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
