//
//  SmartPlaybackService.swift
//  flo
//

import CoreData
import Foundation

/// Generates personalized song recommendations from on-device listening data.
///
/// All heavy work (library cache decode, history aggregation, scoring) runs off
/// the main thread; callers `await generateMix` and receive plain `Song` values.
final class SmartPlaybackService {
  static let shared = SmartPlaybackService()

  /// Playback context for auto-continue: biases results toward the genre and
  /// artist of the song that just finished, away from its album.
  struct Seed {
    let artist: String
    let albumId: String
  }

  /// Immutable aggregate of listening history, built in a single pass on a
  /// background Core Data context so scoring never touches managed objects.
  private struct ListeningSnapshot {
    var totalListens = 0
    var artistPlays: [String: Int] = [:]
    var albumPlays: [String: Int] = [:]
    var recentArtists: Set<String> = []
    var recentAlbumIds: Set<String> = []
    var cooldownSongIds: Set<String> = []
    var cooldownTitlesByArtist: [String: Set<String>] = [:]
    var skippedSongIds: Set<String> = []
    var skipCountByArtist: [String: Int] = [:]
  }

  private static let historyWindowDays = 365
  private static let recencyWindowDays = 14
  private static let replayCooldownMinutes = 30
  private static let skipWindowDays = 30
  private static let coldStartThreshold = 20
  private static let songCacheMaxAge: TimeInterval = 24 * 60 * 60
  // A full fetch takes big pages to keep the round trips down; the
  // incremental walk usually ends within its first small one.
  private static let fullPageSize = 1000
  private static let incrementalPageSize = 200
  private static let songPageCap = 500

  private let syncLock = NSLock()
  private var syncRun: (id: UUID, task: Task<[Song], Never>, forced: Bool)?

  private init() {}

  /// Build a fresh mix of `count` songs. `queueIds` are excluded from the
  /// candidates; `seed` biases scoring toward the current playback context.
  func generateMix(count: Int, seed: Seed? = nil, queueIds: Set<String> = []) async -> [Song] {
    guard count > 0 else { return [] }

    var (songs, albums, starredIds) = await loadCachedLibrary()

    // Library songs are only playable when the server answers; with the
    // network up but the server away they would all fail to stream.
    let canStream = await ConnectivityMonitor.shared.canStream()

    if canStream {
      if songs.isEmpty {
        songs = await syncSongLibrary()
        starredIds = await loadCachedLibrary().starredIds
      } else if Self.isSongCacheStale() {
        // Use the cached library now and refresh it for the next mix, so new
        // songs show up and deleted ones drop out.
        Task(priority: .utility) { _ = await self.syncSongLibrary() }
      }
    }
    if !canStream || songs.isEmpty {
      songs = await offlinePlayableSongs()
    }
    guard !songs.isEmpty else { return [] }

    let listening = await listeningSnapshot()
    var rng = SystemRandomNumberGenerator()

    return Self.rank(
      songs: songs, albums: albums, starredIds: starredIds, listening: listening,
      seed: seed, queueIds: queueIds, count: count, rng: &rng)
  }

  /// Refetches the cached song library in the background, e.g. when its
  /// songs keep failing to stream because the server rebuilt its ids.
  func refreshSongLibrary() {
    Task(priority: .utility) { _ = await syncSongLibrary(force: true) }
  }

  /// Brings the cached song library up to date with as little traffic as the
  /// server's answers allow and returns it. Concurrent callers share one run;
  /// `force` refetches everything (the server may have rebuilt its ids).
  func syncSongLibrary(force: Bool = false) async -> [Song] {
    let task: Task<[Song], Never> = syncLock.withLock {
      if let running = syncRun, running.forced || !force { return running.task }
      // A forced refetch follows the unforced run it found instead of joining it.
      let previous = syncRun?.task
      let id = UUID()
      let task = Task {
        defer { self.syncLock.withLock { if self.syncRun?.id == id { self.syncRun = nil } } }
        _ = await previous?.value
        let generation = LibraryCacheManager.shared.generation
        let songs = await self.performSongSync(force: force, generation: generation)
        // After a logout mid-sync, no mix may be built from the previous account.
        return LibraryCacheManager.shared.generation == generation ? songs : []
      }
      syncRun = (id, task, force)
      return task
    }
    return await task.value
  }

  // MARK: - Data loading

  private static func isSongCacheStale() -> Bool {
    guard let written = LibraryCacheManager.shared.modificationDate(forKey: "songs.stamp") else {
      return true
    }
    return Date().timeIntervalSince(written) > songCacheMaxAge
  }

  /// Blocking JSON cache reads run on a GCD queue so the cooperative thread
  /// pool never blocks on disk.
  private func loadCachedLibrary() async -> (
    songs: [Song], albums: [Album], starredIds: Set<String>
  ) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let songs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
        let albums = LibraryCacheManager.shared.load([Album].self, forKey: "albums") ?? []
        let starred = LibraryCacheManager.shared.load([Song].self, forKey: "starredSongs") ?? []
        continuation.resume(returning: (songs, albums, Set(starred.map { $0.playbackID })))
      }
    }
  }

  private func performSongSync(force: Bool, generation: Int) async -> [Song] {
    let (cached, cachedStamp) = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let songs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
        let stamp = LibraryCacheManager.shared.load(LibraryStamp.self, forKey: "songs.stamp")
        continuation.resume(returning: (songs, stamp))
      }
    }

    guard
      let stamp = try? await withCheckedThrowingContinuation({ continuation in
        AlbumService.shared.getLibraryStamp(entity: "song") { continuation.resume(with: $0) }
      })
    else { return cached }

    // Stars leave updatedAt alone, so the starred list is refreshed on every
    // run that reaches the server; the cached library's own flags go stale.
    let starredRequestedAt = Date()
    if let starred = try? await withCheckedThrowingContinuation({ continuation in
      AlbumService.shared.getStarredSongs { continuation.resume(with: $0) }
    }) {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          // The Liked Songs screen may have saved a newer list meanwhile.
          let saved = LibraryCacheManager.shared.modificationDate(forKey: "starredSongs")
          if saved.map({ $0 < starredRequestedAt }) ?? true {
            LibraryCacheManager.shared.save(starred, forKey: "starredSongs", generation: generation)
          }
          continuation.resume()
        }
      }
    }

    let unchanged =
      !force && stamp.total != nil && stamp == cachedStamp && cached.count == stamp.total
    var mode = unchanged ? "unchanged" : "full"
    var pages = 0
    var fetched = 0
    var songs = cached

    let newest = stamp.newestUpdatedAt.flatMap(Self.second)
    let cachedNewest = cachedStamp?.newestUpdatedAt.flatMap(Self.second)
    // Pages come newest first, so only songs changed since the cached newest
    // second need fetching. Deletions show up as a count that does not add
    // up, and only a full fetch can tell which songs went away.
    if !unchanged, !force, !cached.isEmpty, let total = stamp.total, total >= cached.count,
      let newest, let cachedNewest, newest >= cachedNewest
    {
      guard let page = await fetchSongPages(total: total, since: cachedNewest) else {
        return cached
      }
      pages = page.pages
      fetched = page.songs.count
      let fetchedIds = Set(page.songs.map(\.id))
      let merged = page.songs + cached.filter { !fetchedIds.contains($0.id) }
      if merged.count == total {
        mode = "incremental"
        songs = merged
      }
    }

    if mode == "full" {
      guard let page = await fetchSongPages(total: stamp.total, since: nil) else { return cached }
      pages += page.pages
      fetched += page.songs.count
      // A scan moving songs between pages leaves a gap; the next run gets them.
      guard stamp.total.map({ $0 == page.songs.count }) ?? true else { return cached }
      songs = page.songs
    }

    debugLog(
      "song sync: mode=\(mode) total=\(String(describing: stamp.total)) "
        + "newest=\(stamp.newestUpdatedAt ?? "-") cached=\(cached.count) pages=\(pages) "
        + "fetched=\(fetched) merged=\(songs.count)")

    // Saving an unchanged stamp again touches its date, which restarts the
    // staleness timer.
    // Written before returning, so a run chained after this one reads them.
    let library = unchanged ? nil : songs
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        if let library {
          LibraryCacheManager.shared.save(library, forKey: "songs", generation: generation)
        }
        LibraryCacheManager.shared.save(stamp, forKey: "songs.stamp", generation: generation)
        continuation.resume()
      }
    }
    return songs
  }

  /// Pages through the songs most recently changed first, holding only the
  /// current page besides the result. With `since`, keeps the songs changed in
  /// or after that second and stops at the first page reaching older ones.
  /// Nil when a page fails.
  private func fetchSongPages(total: Int?, since: Date?) async -> (songs: [Song], pages: Int)? {
    let pageSize = since == nil ? Self.fullPageSize : Self.incrementalPageSize
    var songs: [Song] = []
    // A scan shifting the pages under the walk can repeat a song.
    var seen = Set<String>()
    var pages = 0
    var start = 0

    while pages < Self.songPageCap, total.map({ start < $0 }) ?? true {
      let end = start + pageSize
      guard
        let page = try? await withCheckedThrowingContinuation({ continuation in
          AlbumService.shared.getSongsPage(start: start, end: end) { continuation.resume(with: $0) }
        })
      else { return nil }
      pages += 1

      var reachedOlder = false
      for item in page {
        if let since, let changed = item.updatedAt.flatMap(Self.second), changed < since {
          reachedOlder = true
          break
        }
        if seen.insert(item.song.id).inserted { songs.append(item.song) }
      }
      if reachedOlder || page.count < pageSize { break }
      start = end
    }
    return (songs, pages)
  }

  private static let secondFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  /// The whole second of an ISO-8601 timestamp. Navidrome sends fractional
  /// seconds only sometimes, and songs sharing a second must compare equal.
  private static func second(of iso: String) -> Date? {
    var text = iso
    if let dot = text.firstIndex(of: "."),
      let zone = text[dot...].firstIndex(where: { "Z+-".contains($0) })
    {
      text.removeSubrange(dot..<zone)
    }
    return secondFormatter.date(from: text)
  }

  /// Candidate pool when offline: only songs playable without a connection
  /// (downloaded albums/playlists plus the transparent stream cache).
  /// viewContext-backed reads, so this hops to the main actor.
  private func offlinePlayableSongs() async -> [Song] {
    await MainActor.run {
      let downloaded = CoreDataManager.shared.getRecordsByEntity(entity: SongEntity.self)
        .map(Song.init)

      var seen = Set<String>()
      var pool: [Song] = []
      for song in downloaded + StreamCacheManager.shared.getCachedSongs() {
        let key = song.playbackID
        guard !key.isEmpty, seen.insert(key).inserted else { continue }
        pool.append(song)
      }
      return pool
    }
  }

  private func listeningSnapshot() async -> ListeningSnapshot {
    let now = Date()
    let calendar = Calendar.current
    let historyCutoff =
      calendar.date(byAdding: .day, value: -Self.historyWindowDays, to: now) ?? .distantPast
    let recencyCutoff =
      calendar.date(byAdding: .day, value: -Self.recencyWindowDays, to: now) ?? now
    let cooldownCutoff =
      calendar.date(byAdding: .minute, value: -Self.replayCooldownMinutes, to: now) ?? now
    let skipCutoff =
      calendar.date(byAdding: .day, value: -Self.skipWindowDays, to: now) ?? now

    let context = CoreDataManager.shared.persistentContainer.newBackgroundContext()

    return await context.perform {
      var snapshot = ListeningSnapshot()

      let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
      request.predicate = NSPredicate(format: "timestamp >= %@", historyCutoff as NSDate)
      guard let history = try? context.fetch(request) else { return snapshot }

      // Per-song skip counts, capped when aggregated per artist so one broken
      // track cannot sink its artist.
      var skipsBySong: [String: (artistKey: String, count: Int)] = [:]

      for entry in history {
        guard let timestamp = entry.timestamp else { continue }

        let artistKey = entry.artistName.map(Self.artistKey) ?? ""
        let albumId = entry.albumId ?? ""

        // Skips never count as listens, but a just-skipped song still enters
        // the replay cooldown.
        if entry.skipped {
          if let songId = entry.songId, !songId.isEmpty {
            if timestamp >= skipCutoff {
              skipsBySong[songId] = (artistKey, (skipsBySong[songId]?.count ?? 0) + 1)
            }
            if timestamp >= cooldownCutoff {
              snapshot.cooldownSongIds.insert(songId)
            }
          }
          continue
        }

        snapshot.totalListens += 1

        if !artistKey.isEmpty {
          snapshot.artistPlays[artistKey, default: 0] += 1
        }
        if !albumId.isEmpty {
          snapshot.albumPlays[albumId, default: 0] += 1
        }
        if timestamp >= recencyCutoff {
          if !artistKey.isEmpty { snapshot.recentArtists.insert(artistKey) }
          if !albumId.isEmpty { snapshot.recentAlbumIds.insert(albumId) }
        }
        if timestamp >= cooldownCutoff {
          if let songId = entry.songId, !songId.isEmpty {
            snapshot.cooldownSongIds.insert(songId)
          }
          if let track = entry.trackName, !track.isEmpty, !artistKey.isEmpty {
            snapshot.cooldownTitlesByArtist[artistKey, default: []]
              .insert(Self.normalizeTitle(track))
          }
        }
      }

      for (songId, entry) in skipsBySong {
        snapshot.skippedSongIds.insert(songId)
        if !entry.artistKey.isEmpty {
          snapshot.skipCountByArtist[entry.artistKey, default: 0] += min(entry.count, 3)
        }
      }

      return snapshot
    }
  }

  // MARK: - Ranking

  private static func rank<R: RandomNumberGenerator>(
    songs: [Song], albums: [Album], starredIds: Set<String>,
    listening: ListeningSnapshot, seed: Seed?, queueIds: Set<String>,
    count: Int, rng: inout R
  ) -> [Song] {
    var albumGenres: [String: String] = [:]
    for album in albums where !album.genre.isEmpty {
      albumGenres[album.id] = album.genre
    }

    // The starred list is the only current source; a cached song's own flag
    // outlives an unstar, since stars leave updatedAt alone.
    func isStarred(_ song: Song) -> Bool {
      starredIds.contains(song.playbackID)
    }
    func isEligible(_ song: Song) -> Bool {
      if queueIds.contains(song.id) || queueIds.contains(song.playbackID) { return false }
      if listening.cooldownSongIds.contains(song.playbackID) { return false }
      guard let titles = listening.cooldownTitlesByArtist[artistKey(song.artist)] else {
        return true
      }
      return !titles.contains(normalizeTitle(song.title))
    }

    // Cold start: not enough history to score meaningfully — starred songs
    // first, then the rest, both shuffled, with the same diversity caps.
    // Recently skipped songs stay out even here.
    if listening.totalListens < coldStartThreshold {
      let starred = songs.filter(isStarred).shuffled(using: &rng)
      let rest = songs.filter { !isStarred($0) }.shuffled(using: &rng)
      let pool = (starred + rest).lazy
        .filter { isEligible($0) && !listening.skippedSongIds.contains($0.playbackID) }
        .prefix(count * 5)
      return select(from: pool.map { ($0, 1.0) }, count: count, weighted: false, rng: &rng)
    }

    // Genre affinity comes from listens (album plays joined to album genres),
    // not from how many albums of a genre happen to be in the library.
    var genrePlays: [String: Int] = [:]
    for (albumId, plays) in listening.albumPlays {
      if let genre = albumGenres[albumId] {
        genrePlays[genre, default: 0] += plays
      }
    }

    let logMaxArtistPlays = log1p(Double(listening.artistPlays.values.max() ?? 0))
    let maxGenrePlays = Double(genrePlays.values.max() ?? 0)
    let seedArtistKey = seed.map { artistKey($0.artist) }
    let seedGenre = seed.flatMap { albumGenres[$0.albumId] }

    var scored: [(Song, Double)] = []
    scored.reserveCapacity(songs.count)

    for song in songs {
      let key = artistKey(song.artist)
      var score = 0.0

      // Artist affinity (0.30), log-scaled so one dominant artist does not
      // crush the long tail to zero.
      if logMaxArtistPlays > 0 {
        let plays = Double(listening.artistPlays[key] ?? 0)
        score += (log1p(plays) / logMaxArtistPlays) * 0.30
      }

      // Starred (0.25)
      if isStarred(song) { score += 0.25 }

      // Recency (0.20 total: 0.10 artist + 0.10 album)
      if listening.recentArtists.contains(key) { score += 0.10 }
      if listening.recentAlbumIds.contains(song.albumId) { score += 0.10 }

      // Genre affinity (0.15), proportional to listens in that genre
      if maxGenrePlays > 0, let genre = albumGenres[song.albumId] {
        score += (Double(genrePlays[genre] ?? 0) / maxGenrePlays) * 0.15
      }

      // Skip pressure: a recently skipped song is penalized directly, an
      // artist with repeated skips slightly.
      if listening.skippedSongIds.contains(song.playbackID) { score -= 0.15 }
      if let skips = listening.skipCountByArtist[key], skips > 0 {
        score -= min(Double(skips), 5) / 5 * 0.05
      }

      // Playback context: continue in the same lane, but not the same album.
      // Empty ids never match — otherwise a non-album single would penalize
      // every other single in the library.
      if let seed {
        if let seedGenre, albumGenres[song.albumId] == seedGenre { score += 0.15 }
        if !key.isEmpty, key == seedArtistKey { score += 0.05 }
        if !seed.albumId.isEmpty, song.albumId == seed.albumId { score -= 0.20 }
      }

      scored.append((song, score))
    }

    scored.sort { $0.1 > $1.1 }

    // Exclusions run only while filling the pool, so title normalization
    // touches a few hundred candidates instead of the whole library.
    var pool: [(Song, Double)] = []
    pool.reserveCapacity(count * 5)
    for (song, score) in scored {
      if pool.count >= count * 5 { break }
      if isEligible(song) { pool.append((song, score)) }
    }

    return select(from: pool, count: count, weighted: true, rng: &rng)
  }

  /// Sample `count` songs from the pool — weighted by score when `weighted`,
  /// in pool order otherwise — enforcing per-artist/per-album diversity caps.
  private static func select<R: RandomNumberGenerator>(
    from pool: [(Song, Double)], count: Int, weighted: Bool, rng: inout R
  ) -> [Song] {
    guard !pool.isEmpty else { return [] }

    let maxPerArtist = max(2, count / 10)
    let maxPerAlbum = max(2, count / 10)

    var remaining = pool
    var selected: [Song] = []
    var overflow: [Song] = []
    var artistCounts: [String: Int] = [:]
    var albumCounts: [String: Int] = [:]

    while selected.count < count, !remaining.isEmpty {
      var index = 0
      if weighted {
        let totalWeight = remaining.reduce(0.0) { $0 + max($1.1, 0.01) }
        var roll = Double.random(in: 0..<totalWeight, using: &rng)
        index = remaining.count - 1
        for (i, item) in remaining.enumerated() {
          roll -= max(item.1, 0.01)
          if roll <= 0 {
            index = i
            break
          }
        }
      }

      let song = remaining.remove(at: index).0
      let key = artistKey(song.artist)

      if artistCounts[key, default: 0] >= maxPerArtist
        || albumCounts[song.albumId, default: 0] >= maxPerAlbum
      {
        overflow.append(song)
        continue
      }

      artistCounts[key, default: 0] += 1
      albumCounts[song.albumId, default: 0] += 1
      selected.append(song)
    }

    // Relax the caps if they prevented filling the request.
    if selected.count < count {
      selected.append(contentsOf: overflow.prefix(count - selected.count))
    }

    return spreadArtists(selected)
  }

  /// Push apart back-to-back songs by the same artist where possible.
  private static func spreadArtists(_ songs: [Song]) -> [Song] {
    guard songs.count > 2 else { return songs }

    var result = songs
    for i in 1..<result.count {
      let previous = artistKey(result[i - 1].artist)
      guard artistKey(result[i].artist) == previous else { continue }
      if let swap = ((i + 1)..<result.count).first(where: {
        artistKey(result[$0].artist) != previous
      }) {
        result.swapAt(i, swap)
      }
    }
    return result
  }

  // MARK: - Normalization

  /// Case- and diacritic-insensitive key so "Beyoncé" and "beyonce" pool
  /// their plays.
  private static func artistKey(_ artist: String) -> String {
    artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Strip version markers ("(Live)", "[2019 Remaster]", "- acoustic",
  /// "feat. X") so variants of a just-played track share its cooldown, while
  /// distinguishing parentheticals like "Intro (North)" are left intact.
  private static func normalizeTitle(_ title: String) -> String {
    var t = title.lowercased()
    t = t.replacingOccurrences(
      of:
        #"\s*[\(\[](live|remaster(ed)?|acoustic|demo|deluxe|bonus|mono|stereo|single|radio|remix|edit|version|feat\.?|ft\.?|\d{4})[^\)\]]*[\)\]]"#,
      with: "", options: .regularExpression)
    t = t.replacingOccurrences(
      of:
        #"\s*[-–—]\s*(live|remaster(ed)?|acoustic|bonus(\s+track)?|demo|remix|edit|deluxe|radio|single|mono|stereo|version).*$"#,
      with: "", options: .regularExpression)
    t = t.replacingOccurrences(
      of: #"\s*(feat\.|ft\.)\s.*$"#, with: "", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Song {
  fileprivate var playbackID: String {
    mediaFileId.isEmpty ? id : mediaFileId
  }
}
