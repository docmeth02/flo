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

  /// What a continuation knows about the session it continues.
  struct KeepPlayingContext {
    let seed: Seed
    let anchorGenres: Set<String>
    let sessionMinutes: Double
    let queueIds: Set<String>
  }

  enum MixMode {
    case playSomething
    case keepPlaying(KeepPlayingContext)
  }

  /// Build a fresh mix of `count` songs for a listening mode.
  func generateMix(count: Int, mode: MixMode) async -> [Song] {
    await mix(count: count, mode: mode).songs
  }

  /// The cached library keyed by playback id, with the keys listening history
  /// is aggregated under: plays mirrored from the server join songs through it.
  struct LibraryIndex: Sendable {
    struct Entry: Sendable {
      let artistKey: String
      let albumId: String
      let genres: [String]
      /// Decade such as "1990s"; nil without a year.
      let era: String?

      /// The keys of a song, from its own metadata.
      init(_ song: Song) {
        let artistId = song.artistId ?? ""
        var genres = song.genres ?? []
        if genres.isEmpty, let genre = song.genre { genres = [genre] }
        artistKey = artistId.isEmpty ? SmartPlaybackService.artistKey(song.artist) : artistId
        albumId = song.albumId
        self.genres = genres.filter { !$0.isEmpty }
        era = song.year.flatMap { $0 > 0 ? "\($0 / 10 * 10)s" : nil }
      }
    }

    let songs: [String: Entry]
  }

  private static let songCacheMaxAge: TimeInterval = 24 * 60 * 60
  // A full fetch takes big pages to keep the round trips down; the
  // incremental walk usually ends within its first small one.
  private static let fullPageSize = 1000
  private static let incrementalPageSize = 200
  private static let songPageCap = 500

  private let syncLock = NSLock()
  private let indexLock = NSLock()
  private var indexCache: (stampDate: Date?, index: LibraryIndex)?
  private var syncRun: (id: UUID, task: Task<[Song], Never>, forced: Bool)?

  private init() {}

  /// The mix and the record of why each song made it; the record also goes
  /// to the recommendation log.
  func mix(count: Int, mode: MixMode) async -> (songs: [Song], record: MixRecord?) {
    guard count > 0 else { return ([], nil) }
    Task(priority: .utility) { await ListeningHistoryStore.shared.refreshIfStale(reason: .mix) }

    var (songs, starredIds) = await loadCachedLibrary()

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
    guard !songs.isEmpty else { return ([], nil) }

    async let affinity = ListeningHistoryStore.shared.snapshot()
    async let journal = PlaybackJournal.shared.snapshot()
    let index = await libraryIndex(allowSync: canStream)
    let ratings = await MainActor.run { RatingStore.shared.ratings }
    var rng = SplitMix64(seed: Self.debugSeed ?? .random(in: .min ... .max))

    let started = DispatchTime.now().uptimeNanoseconds
    let (picked, record) = MixRanker().rank(
      library: songs, index: index, affinity: await affinity, journal: await journal,
      ratings: ratings, starred: starredIds, mode: mode, count: count, now: Date(), rng: &rng)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

    await MainActor.run { RecommendationLog.shared.record(record) }
    debugLog(
      "mix: mode=\(record.mode) songs=\(picked.count)/\(count) of \(songs.count) "
        + "eligible=\(record.eligible) explore=\(String(format: "%.2f", record.exploreShare)) "
        + "ranker=\(String(format: "%.1f", elapsed))ms")
    return (picked, record)
  }

  private static var debugSeed: UInt64? {
    #if DEBUG
      ProcessInfo.processInfo.environment["FLO_DEBUG_RNG_SEED"].flatMap(UInt64.init)
    #else
      nil
    #endif
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
  func loadCachedLibrary() async -> (songs: [Song], starredIds: Set<String>) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let songs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
        let starred = LibraryCacheManager.shared.load([Song].self, forKey: "starredSongs") ?? []
        continuation.resume(returning: (songs, Set(starred.map { $0.playbackID })))
      }
    }
  }

  /// Built from the cached song library on every call. A library that is
  /// missing or cached without the metadata is synced first, so plays are
  /// never folded without their genres and decades.
  func libraryIndex(allowSync: Bool = true) async -> LibraryIndex {
    // Decoding the whole cache is the expensive part; the stamp's date says
    // whether the cache changed since the last index was built.
    let stampDate = LibraryCacheManager.shared.modificationDate(forKey: "songs.stamp")
    if let cached = indexLock.withLock({ indexCache }), cached.stampDate == stampDate,
      stampDate != nil
    {
      return cached.index
    }
    let (cached, format) = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let songs = LibraryCacheManager.shared.load([Song].self, forKey: "songs") ?? []
        let stamp = LibraryCacheManager.shared.load(LibraryStamp.self, forKey: "songs.stamp")
        continuation.resume(returning: (songs, stamp?.format))
      }
    }
    // Remembered as of before the songs were read: a sync landing meanwhile
    // leaves a newer stamp, so the next call builds the index again.
    var builtFrom = stampDate
    var songs = cached
    if cached.isEmpty || format != LibraryStamp.currentFormat {
      // Offline, a sync would only wait out its timeouts.
      guard allowSync else { return LibraryIndex(songs: [:]) }
      builtFrom = nil
      songs = await syncSongLibrary()
      // A failed sync hands back the old cache; plays folded from it would
      // keep missing genres and artist ids for good, so the import waits.
      let synced = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          let stamp = LibraryCacheManager.shared.load(LibraryStamp.self, forKey: "songs.stamp")
          continuation.resume(returning: stamp?.format == LibraryStamp.currentFormat)
        }
      }
      // A stamp can outlive an evicted song cache; an empty library is never
      // remembered as the index.
      guard synced, !songs.isEmpty else { return LibraryIndex(songs: [:]) }
      builtFrom = LibraryCacheManager.shared.modificationDate(forKey: "songs.stamp")
    }

    var entries: [String: LibraryIndex.Entry] = [:]
    entries.reserveCapacity(songs.count)
    for song in songs {
      entries[song.playbackID] = LibraryIndex.Entry(song)
    }
    let index = LibraryIndex(songs: entries)
    indexLock.withLock { indexCache = (builtFrom, index) }
    return index
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
    // Ratings leave updatedAt alone as well.
    await RatingStore.shared.refreshFromServer()

    // Songs cached before the metadata fields lack them.
    let force = force || cachedStamp?.format != stamp.format
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

  // MARK: - Normalization

  /// Case- and diacritic-insensitive key so "Beyoncé" and "beyonce" pool
  /// their plays.
  static func artistKey(_ artist: String) -> String {
    artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Strip version markers ("(Live)", "[2019 Remaster]", "- acoustic",
  /// "feat. X") so variants of a just-played track share its cooldown, while
  /// distinguishing parentheticals like "Intro (North)" are left intact.
  static func normalizeTitle(_ title: String) -> String {
    var t = title.lowercased()
    // Regular expressions are slow and most titles lack what they look for.
    if t.contains("(") || t.contains("[") {
      t = t.replacingOccurrences(
        of:
          #"\s*[\(\[](live|remaster(ed)?|acoustic|demo|deluxe|bonus|mono|stereo|single|radio|remix|edit|version|feat\.?|ft\.?|\d{4})[^\)\]]*[\)\]]"#,
        with: "", options: .regularExpression)
    }
    if t.contains(where: { "-–—".contains($0) }) {
      t = t.replacingOccurrences(
        of:
          #"\s*[-–—]\s*(live|remaster(ed)?|acoustic|bonus(\s+track)?|demo|remix|edit|deluxe|radio|single|mono|stereo|version).*$"#,
        with: "", options: .regularExpression)
    }
    if t.contains("feat.") || t.contains("ft.") {
      t = t.replacingOccurrences(
        of: #"\s*(feat\.|ft\.)\s.*$"#, with: "", options: .regularExpression)
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
