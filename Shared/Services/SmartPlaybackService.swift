//
//  SmartPlaybackService.swift
//  flo
//

import CoreData
import Foundation

/// Generates personalized song recommendations from on-device listening data.
///
/// All heavy work (library cache decode, history aggregation, scoring) runs off
/// the main thread; callers `await mix` and receive plain `Song` values.
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

  /// The cached library keyed by playback id, with the keys listening history
  /// is aggregated under: plays mirrored from the server join songs through it.
  struct LibraryIndex: Sendable {
    struct Entry: Sendable {
      /// The artist history is stored under: the server's artist id, else
      /// the artist key.
      let historyArtistKey: String
      /// The server's artist id; nil for a song without one.
      let artistId: String?
      /// One artist for recommendations across spellings (ArtistIdentity),
      /// else the server's artist id; "" for neither.
      let artistKey: String
      let albumId: String
      let genres: [String]
      /// Decade such as "1990s"; nil without a year.
      let era: String?

      /// The keys of a song from its own metadata, `artistKeys` mapping server
      /// artist ids to identity keys. An artist missing from them keeps its
      /// server id: the song's own artist tag may name guests as well.
      init(_ song: Song, artistKeys: [String: String] = [:]) {
        let artistId = song.artistId ?? ""
        self.artistId = artistId.isEmpty ? nil : artistId
        var genres = song.genres ?? []
        if genres.isEmpty, let genre = song.genre { genres = [genre] }
        if artistId.isEmpty {
          artistKey = ArtistIdentity.key(name: song.artist, mbid: nil) ?? ""
          // The folded name, which history rows of songs without an artist id use.
          historyArtistKey = song.artist
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        } else {
          artistKey = artistKeys[artistId] ?? artistId
          historyArtistKey = artistId
        }
        albumId = song.albumId
        self.genres = genres.filter { !$0.isEmpty }
        era = song.year.flatMap { $0 > 0 ? "\($0 / 10 * 10)s" : nil }
      }
    }

    let songs: [String: Entry]
    /// History artist key → artist key, for every artist in the library.
    let artistKeys: [String: String]

    init(songs: [String: Entry]) {
      self.songs = songs
      artistKeys = songs.values.reduce(into: [:]) { $0[$1.historyArtistKey] = $1.artistKey }
    }
  }

  private static let songCacheMaxAge: TimeInterval = 24 * 60 * 60
  /// The plays a reason counts, and Taste's: those of the last 60 days.
  static let reasonWindow: TimeInterval = 60 * 86400
  // A reachable server answers the probe within a second or two.
  private static let verdictWait: Duration = .seconds(4)
  // A full fetch takes big pages to keep the round trips down; the
  // incremental walk usually ends within its first small one.
  private static let fullPageSize = 1000
  private static let incrementalPageSize = 200
  private static let songPageCap = 500

  private let syncLock = NSLock()
  private let indexLock = NSLock()
  private let starredLock = NSLock()
  private var starredRefresh: Task<Void, Never>?
  private var indexCache: (stampDate: Date?, artistsDate: Date?, index: LibraryIndex)?
  private var syncRun: (id: UUID, task: Task<[Song], Never>, forced: Bool)?

  private init() {}

  /// The mix and the record of why each song made it; the record also goes
  /// to the recommendation log.
  func mix(count: Int, mode: MixMode) async -> (songs: [Song], record: MixRecord?) {
    guard count > 0 else { return ([], nil) }
    Task(priority: .utility) { await ListeningHistoryStore.shared.refreshIfStale(reason: .mix) }

    var (songs, starredIds) = await loadCachedLibrary()

    // Library songs are only playable when the server answers; with the
    // network up but the server away they would all fail to stream. Offline
    // the probe only ends with its timeout, so songs on the watch play once
    // it has not answered for a few seconds.
    let monitor = ConnectivityMonitor.shared
    var verdict = await monitor.canStream(waitingAtMost: Self.verdictWait)
    if verdict == nil, await offlinePlayableSongs().isEmpty {
      verdict = await monitor.canStream()
    }
    let canStream = verdict ?? false

    if canStream {
      // Likes made elsewhere, or by Siri in an earlier session, reach the
      // next mix; the song sync below refreshes them too.
      let generation = LibraryCacheManager.shared.generation
      Task(priority: .utility) { await self.refreshStarred(generation: generation) }
      if songs.isEmpty {
        songs = await syncSongLibrary()
        starredIds = await loadCachedLibrary().starredIds
      } else if Self.isSongCacheStale() {
        // Use the cached library now and refresh it for the next mix, so new
        // songs show up and deleted ones drop out.
        Task(priority: .utility) { _ = await self.syncSongLibrary() }
      }
    }
    // Streaming switched off on this network (the phone on cellular) leaves
    // the songs on the device as well.
    if !canStream || songs.isEmpty || TranscodingSettings.streamingBitRate == nil {
      songs = await offlinePlayableSongs()
    }
    guard !songs.isEmpty else { return ([], nil) }

    async let affinity = ListeningHistoryStore.shared.snapshot()
    async let journal = PlaybackJournal.shared.snapshot()
    async let recentPlays = ListeningHistoryStore.shared.playCounts(
      since: Date().addingTimeInterval(-Self.reasonWindow))
    // Ratings changed in another client since the last refresh count when
    // the server answers quickly.
    if canStream, case .playSomething = mode {
      await RatingStore.shared.refreshIfStale(waitingAtMost: .seconds(3))
    }
    let index = await libraryIndex(allowSync: canStream)
    let pendingPlays = Self.latestListens(ScrobbleQueueManager.shared.pendingListens())
    let liked = await likedCollections(index: index)
    let (ratings, starred) = await MainActor.run { [songs, starredIds] in
      (Self.effectiveRatings(of: songs, index: index), StarStore.shared.starred(listed: starredIds))
    }
    var seed = UInt64.random(in: .min ... .max)
    #if DEBUG
      seed = Self.debugSeed ?? seed
    #endif
    var rng = SplitMix64(seed: seed)

    let started = DispatchTime.now().uptimeNanoseconds
    let (picked, record) = MixRanker().rank(
      library: songs, index: index, affinity: await affinity, journal: await journal,
      pendingPlays: pendingPlays, recentPlays: await recentPlays, ratings: ratings,
      starred: starred, likedAlbums: liked.albums, likedArtists: liked.artists, mode: mode,
      count: count, now: Date(), rng: &rng)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

    await MainActor.run { RecommendationLog.shared.record(record) }
    debugLog(
      "mix: mode=\(record.mode) songs=\(picked.count)/\(count) of \(songs.count) "
        + "eligible=\(record.eligible) explore=\(String(format: "%.2f", record.exploreShare)) "
        + "ranker=\(String(format: "%.1f", elapsed))ms")
    return (picked, record)
  }

  /// The rating each song brings into a mix: its own (pending or
  /// confirmed), else its album's, else its artist's, where any spelling of
  /// the artist (ArtistIdentity) speaks for all; unrated songs are absent.
  /// `store` is for tests.
  @MainActor static func effectiveRatings(
    of songs: [Song], index: LibraryIndex, store: RatingStore = .shared
  ) -> [String: MixRanker.Rating] {
    // Spellings rated differently: the lowest wins, so a boosted spelling
    // never brings back an avoided artist.
    let artistRatings = store.artistRatings.reduce(into: [String: Int]()) { result, rating in
      let key = index.artistKeys[rating.key] ?? rating.key
      result[key] = min(result[key] ?? rating.value, rating.value)
    }
    var ratings: [String: MixRanker.Rating] = [:]
    for song in songs {
      let id = song.playbackID
      if let stars = store.ratings[id] {
        ratings[id] = MixRanker.Rating(stars: stars, source: .song)
      } else if let stars = store.albumRatings[song.albumId] {
        ratings[id] = MixRanker.Rating(stars: stars, source: .album)
      } else if !artistRatings.isEmpty {
        let key =
          index.songs[id]?.artistKey
          ?? LibraryIndex.Entry(song, artistKeys: index.artistKeys).artistKey
        if let stars = artistRatings[key] {
          ratings[id] = MixRanker.Rating(stars: stars, source: .artist)
        }
      }
    }
    return ratings
  }

  /// Liked album ids and liked artist keys: the liked lists the song sync
  /// keeps, overlaid with StarStore's. A liked album does not like its album
  /// artist, who on a compilation is not the artist of its songs.
  func likedCollections(index: LibraryIndex) async -> (albums: Set<String>, artists: Set<String>) {
    let liked = await LibraryCacheManager.read {
      $0.load(StarredCollections.self, forKey: .starredCollections)
    }
    // StarStore also knows songs; only the library's albums and artists count.
    let albumIds = Set(index.songs.values.map(\.albumId))
    let artistIds = Set(index.songs.values.compactMap(\.artistId))
    return await MainActor.run {
      let likedAlbums = StarStore.shared.starred(listed: Set(liked?.albums ?? []))
        .intersection(albumIds)
      let likedArtists = StarStore.shared.starred(listed: Set(liked?.artists ?? []))
        .intersection(artistIds)
      return (likedAlbums, Set(likedArtists.map { index.artistKeys[$0] ?? $0 }))
    }
  }

  /// The latest listen per song of plays not delivered yet.
  static func latestListens(_ listens: [(songId: String, at: Date)]) -> [String: Date] {
    listens.reduce(into: [:]) { latest, listen in
      latest[listen.songId] = max(latest[listen.songId] ?? listen.at, listen.at)
    }
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
    guard let written = LibraryCacheManager.shared.modificationDate(forKey: .songsStamp) else {
      return true
    }
    return Date().timeIntervalSince(written) > songCacheMaxAge
  }

  func loadCachedLibrary() async -> (songs: [Song], starredIds: Set<String>) {
    await LibraryCacheManager.read { cache in
      let songs = cache.load([Song].self, forKey: .songs) ?? []
      let starred = cache.load([Song].self, forKey: .starredSongs) ?? []
      return (songs, Set(starred.map { $0.playbackID }))
    }
  }

  /// Built from the cached song library on every call, with the artists'
  /// identities from the cached artist list. A library that is missing or
  /// cached without the metadata is synced first, so plays are never folded
  /// without their genres and decades.
  func libraryIndex(allowSync: Bool = true) async -> LibraryIndex {
    // Decoding the whole cache is the expensive part; the dates say whether
    // the caches changed since the last index was built.
    let stampDate = LibraryCacheManager.shared.modificationDate(forKey: .songsStamp)
    let artistsDate = LibraryCacheManager.shared.modificationDate(forKey: .artists)
    if let cached = indexLock.withLock({ indexCache }), cached.stampDate == stampDate,
      cached.artistsDate == artistsDate, stampDate != nil
    {
      return cached.index
    }
    let (cached, format, artistKeys) = await LibraryCacheManager.read(qos: .utility) { cache in
      let songs = cache.load([Song].self, forKey: .songs) ?? []
      let stamp = cache.load(LibraryStamp.self, forKey: .songsStamp)
      let artists = cache.load([Artist].self, forKey: .artists) ?? []
      return (songs, stamp?.format, ArtistIdentity.keys(of: artists))
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
      let synced = await LibraryCacheManager.read(qos: .utility) {
        $0.load(LibraryStamp.self, forKey: .songsStamp)?.format == LibraryStamp.currentFormat
      }
      // A stamp can outlive an evicted song cache; an empty library is never
      // remembered as the index.
      guard synced, !songs.isEmpty else { return LibraryIndex(songs: [:]) }
      builtFrom = LibraryCacheManager.shared.modificationDate(forKey: .songsStamp)
    }

    var entries: [String: LibraryIndex.Entry] = [:]
    entries.reserveCapacity(songs.count)
    for song in songs {
      entries[song.playbackID] = LibraryIndex.Entry(song, artistKeys: artistKeys)
    }
    let index = LibraryIndex(songs: entries)
    indexLock.withLock { indexCache = (builtFrom, artistsDate, index) }
    return index
  }

  /// The account's liked songs, albums and artists, for StarStore and the
  /// next mix. One request at a time; a caller joins the one under way.
  private func refreshStarred(generation: Int) async {
    let refresh = starredLock.withLock {
      if let starredRefresh { return starredRefresh }
      let refresh = Task {
        await self.fetchStarred(generation: generation)
        self.starredLock.withLock { self.starredRefresh = nil }
      }
      starredRefresh = refresh
      return refresh
    }
    await refresh.value
  }

  private func fetchStarred(generation: Int) async {
    let requestedAt = Date()
    let since = await MainActor.run { StarStore.shared.listRevision }
    guard let (songs, collections) = try? await AlbumService.shared.getStarred() else { return }
    // The Liked Songs screen may have taken a newer list meanwhile.
    let songsAreNewest = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let saved = LibraryCacheManager.shared.modificationDate(forKey: .starredSongs)
        if saved.map({ $0 < requestedAt }) ?? true {
          LibraryCacheManager.shared.save(songs, forKey: .starredSongs, generation: generation)
        }
        LibraryCacheManager.shared.save(
          collections, forKey: .starredCollections, generation: generation)
        continuation.resume(returning: saved.map { $0 < requestedAt } ?? true)
      }
    }
    guard songsAreNewest else { return }
    await MainActor.run {
      StarStore.shared.adoptServerStars(songs.map(\.playbackID), since: since)
    }
  }

  private func performSongSync(force: Bool, generation: Int) async -> [Song] {
    let (cached, cachedStamp) = await LibraryCacheManager.read { cache in
      (
        cache.load([Song].self, forKey: .songs) ?? [],
        cache.load(LibraryStamp.self, forKey: .songsStamp)
      )
    }

    guard let stamp = try? await AlbumService.shared.getLibraryStamp(entity: "song") else {
      return cached
    }

    // Stars leave updatedAt alone, so the starred list is refreshed on every
    // run that reaches the server; the cached library's own flags go stale.
    await refreshStarred(generation: generation)
    // Ratings leave updatedAt alone as well; activation may have just
    // refreshed them.
    await RatingStore.shared.refreshIfStale()?.value

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
          LibraryCacheManager.shared.save(library, forKey: .songs, generation: generation)
        }
        LibraryCacheManager.shared.save(stamp, forKey: .songsStamp, generation: generation)
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
      guard let page = try? await AlbumService.shared.getSongsPage(start: start, end: end) else {
        return nil
      }
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
  func offlinePlayableSongs() async -> [Song] {
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
