//
//  CarPlayTabs.swift
//  Ownwave
//

import CarPlay
import Combine

/// The SF Symbols of the phone's glyph tiles, and the album placeholder.
enum Glyph {
  static let album = "square.stack"
  static let artist = "music.mic"
  static let playlist = "music.note.list"
  static let radio = "dot.radiowaves.up.forward"
}

// The four tabs and the lists pushed from them.
extension CarPlayController {
  /// Whether the server answers, once per change.
  var reachability: AnyPublisher<Bool, Never> {
    let monitor = ConnectivityMonitor.shared
    return monitor.$isOnline.combineLatest(monitor.$isServerReachable)
      .map { $0 && $1 }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }

  // MARK: - Home

  func homeTab() -> TabScreen {
    let template = tab("Home", "house.fill")
    let playSomething = playSomethingRow()
    app.auth.$isLoggedIn
      .removeDuplicates()
      .filter { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in Task { await self?.loadHome() } }
      .store(in: &subscriptions)
    let changes = Publishers.MergeMany(
      albums.$recentAlbums.map { _ in }.eraseToAnyPublisher(),
      albums.$albums.map { _ in }.eraseToAnyPublisher(),
      albums.$artists.map { _ in }.eraseToAnyPublisher(),
      albums.$playlists.map { _ in }.eraseToAnyPublisher(),
      albums.$starredSongs.map { _ in }.eraseToAnyPublisher(),
      radios.$radios.map { _ in }.eraseToAnyPublisher(),
      PinStore.shared.objectWillChange.eraseToAnyPublisher(),
      StarStore.shared.$stars.map { _ in }.eraseToAnyPublisher(),
      reachability.map { _ in }.eraseToAnyPublisher())
    return TabScreen(
      template: template,
      sections: { [unowned self] in homeSections(playSomething: playSomething) },
      changes: changes.eraseToAnyPublisher(),
      selected: { [unowned self] in
        albums.fetchStarredSongsIfStale()
        let albums = albums
        Task { await albums.loadRecentAlbums() }
      })
  }

  /// What Home shows without asking the server: the library lists from the
  /// cache, so pins resolve, the recent albums and the liked songs, and the
  /// stations once one is pinned.
  private func loadHome() async {
    albums.fetchStarredSongsIfStale()
    await albums.loadRecentAlbums()
    let generation = LibraryCacheManager.shared.generation
    let cachedAlbums = await albums.loadedOrCached(albums.albums, .albums)
    let cachedArtists = await albums.loadedOrCached(albums.artists, .artists)
    let cachedPlaylists = await albums.loadedOrCached(albums.playlists, .playlists)
    // A logout meanwhile, or a list loaded since: the cached copies are stale.
    guard LibraryCacheManager.shared.generation == generation else { return }
    if albums.albums.isEmpty { albums.albums = cachedAlbums }
    if albums.artists.isEmpty { albums.artists = cachedArtists }
    if albums.playlists.isEmpty { albums.playlists = cachedPlaylists }
    if !PinStore.shared.pinned(.radio).isEmpty, radios.radios.isEmpty { radios.fetchAllRadios() }
  }

  /// Play Something, the pins, the recent albums and the liked songs.
  /// Offline the pins and recent albums are the ones downloaded here.
  private func homeSections(playSomething: CPListItem) -> [CPListSection] {
    // Offline, the albums downloaded here.
    let downloaded =
      ConnectivityMonitor.shared.canReachServer
      ? nil : Set(albums.downloadedAlbums.map(\.id))
    let recent =
      downloaded.map { ids in albums.recentAlbums.filter { ids.contains($0.id) } }
      ?? albums.recentAlbums
    var covers: [CarPlayImages.Cover] = []
    var sections = [CPListSection(items: [playSomething])]
    for (title, targets) in [
      ("Pinned", pinned(downloaded: downloaded)), ("Recently Played", recent.map(MenuTarget.album)),
    ] where !targets.isEmpty {
      sections.append(CPListSection(items: [imageRow(title, targets, covers: &covers)]))
    }
    sections.append(CPListSection(items: [likedSongsRow(offline: downloaded != nil)]))
    images.loadCovers(covers, size: CarPlayImages.elementSize)
    return sections
  }

  /// Plays a smart mix; says when one is being built or only downloaded
  /// songs can play, and shows playing while a mix plays.
  private func playSomethingRow() -> CPListItem {
    let item = CPListItem(
      text: "Play Something", detailText: nil,
      image: images.tile("sparkles", .filled, size: CarPlayImages.rowSize))
    item.playingIndicatorLocation = .trailing
    item.handler = { [weak self] _, completion in
      let player = self?.player
      Task {
        // Holds the completion until the mix plays or none came together.
        if await player?.playSomething() == true { self?.showNowPlaying() }
        completion()
      }
    }
    Publishers.CombineLatest(player.$isGeneratingMix, reachability)
      .sink { [weak item] building, online in
        item?.setDetailText(
          building
            ? "Building your mix…"
            : online ? "Smart mix from your listening history" : "Offline · from downloaded songs")
      }
      .store(in: &subscriptions)
    Publishers.CombineLatest3(player.$queue, player.$activeQueueIdx, player.$isPlaying)
      // Published values are set after their subscribers hear of them.
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] _ in
        guard let self, let item else { return }
        let playing = player.isSmartMix && player.isPlaying
        if item.isPlaying != playing { item.isPlaying = playing }
      }
      .store(in: &subscriptions)
    return item
  }

  /// The pins over the library lists, as on the phone's Home; offline only
  /// the albums `downloaded` holds.
  private func pinned(downloaded: Set<String>?) -> [MenuTarget] {
    let pins = PinStore.shared
    guard let downloaded else {
      return pins.targets(
        albums: albums.albums, artists: albums.artists, playlists: albums.playlists,
        radios: radios.radios)
    }
    return pins.targets(albums: albums.albums.filter { downloaded.contains($0.id) })
  }

  /// A titled row of covers and glyph tiles; a tap opens the album, artist
  /// or playlist, or plays the station.
  private func imageRow(
    _ title: String, _ targets: [MenuTarget], covers: inout [CarPlayImages.Cover]
  ) -> CPListImageRowItem {
    let size = CarPlayImages.elementSize
    let targets = Array(targets.prefix(CPMaximumNumberOfGridImages))
    let elements = targets.map { target in
      let element = CPListImageRowItemRowElement(
        image: tile(for: target, size: size), title: target.title, subtitle: target.subtitle)
      if case .album(let album) = target { covers.append(.element(element, albumId: album.id)) }
      return element
    }
    let item = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
    item.listImageRowHandler = { [weak self] _, index, completion in
      if let self, targets.indices.contains(index) {
        switch targets[index] {
        case .album(let album): openAlbum(album)
        case .artist(let artist): openArtist(artist)
        case .playlist(let playlist): openPlaylist(playlist)
        case .radio(let radio): play(radio)
        case .song: break
        }
      }
      completion()
    }
    return item
  }

  /// Opens the Liked tab. Offline it counts the liked songs on the phone.
  private func likedSongsRow(offline: Bool) -> CPListItem {
    let songs = app.likedSongs
    let detail: String
    if offline {
      let local = DownloadStore.localMediaFileIds()
      detail = "\(songs.filter { local.contains($0.playbackID) }.count) downloaded"
    } else {
      detail = counted(songs.count, "song")
    }
    let item = CPListItem(
      text: "Liked Songs", detailText: detail,
      image: images.tile("heart.fill", .liked, size: CarPlayImages.rowSize))
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      self?.selectTab(titled: Self.likedTitle)
      completion()
    }
    return item
  }

  // MARK: - Library

  func libraryTab() -> TabScreen {
    let template = tab("Library", "square.stack.fill")
    let albums = albums
    let radios = radios
    let changes = Publishers.Merge4(
      albums.$albums.map { _ in }, albums.$artists.map { _ in },
      albums.$playlists.map { _ in }, radios.$radios.map { _ in })
    return TabScreen(
      template: template,
      sections: { [unowned self] in
        func count(_ list: [some Any], _ library: AlbumViewModel.Library) -> Int? {
          list.isEmpty && albums.state(library).loadedAt == nil ? nil : list.count
        }
        let size = CarPlayImages.rowSize
        return [
          CPListSection(items: [
            libraryRow(
              "Albums", images.tile(Glyph.album, size: size), noun: "album",
              count: count(albums.albums, .albums), load: albums.refreshAlbums,
              fetch: albums.fetchAlbums, list: { $0.albumsList() }),
            libraryRow(
              "Artists", images.tile(Glyph.artist, round: true, size: size), noun: "artist",
              count: count(albums.artists, .artists), load: albums.refreshArtists,
              fetch: albums.getArtists, list: { $0.artistsList() }),
            libraryRow(
              "Playlists", images.tile(Glyph.playlist, size: size), noun: "playlist",
              count: count(albums.playlists, .playlists), load: albums.refreshPlaylists,
              fetch: albums.getPlaylists, list: { $0.playlistsList() }),
            libraryRow(
              "Radios", images.tile(Glyph.radio, round: true, size: size), noun: "station",
              count: radios.radios.isEmpty && radios.state.loadedAt == nil
                ? nil : radios.radios.count,
              load: radios.refresh, fetch: { radios.fetchAllRadios() },
              list: { $0.radiosList() }),
          ])
        ]
      },
      changes: changes.eraseToAnyPublisher())
  }

  /// A list of the library with its count once loaded. A tap pushes it and
  /// refreshes it as the phone does; a list never loaded loads first.
  private func libraryRow(
    _ title: String, _ image: UIImage, noun: String, count: Int?,
    load: @escaping @MainActor () async -> Void, fetch: @escaping () -> Void,
    list: @escaping (CarPlayController) -> CPListTemplate
  ) -> CPListItem {
    let item = CPListItem(
      text: title, detailText: count.map { counted($0, noun) }, image: image)
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      Task {
        // Holds the completion while a list never loaded loads.
        if count == nil { await load() } else { fetch() }
        if let self { self.push(list(self)) }
        completion()
      }
    }
    return item
  }

  private func albumsList() -> CPListTemplate {
    libraryList("Albums", empty: "No albums yet", items: albums.$albums, cover: \.id) {
      $0.albumRow($1)
    }
  }

  private func artistsList() -> CPListTemplate {
    libraryList("Artists", empty: "No artists yet", items: albums.$artists) { $0.artistRow($1) }
  }

  private func playlistsList() -> CPListTemplate {
    libraryList("Playlists", empty: "No playlists yet", items: albums.$playlists) {
      $0.playlistRow($1)
    }
  }

  private func radiosList() -> CPListTemplate {
    libraryList("Radios", empty: "No radios on the server", items: radios.$radios) {
      $0.radioRow($1)
    }
  }

  /// A pushed list of `items`, rebuilt when they change, with each item's
  /// cover when `cover` names its album. The template keeps the
  /// subscription.
  private func libraryList<Item: Equatable>(
    _ title: String, empty: String, items: Published<[Item]>.Publisher,
    cover: ((Item) -> String)? = nil, row: @escaping (CarPlayController, Item) -> CPListItem
  ) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.emptyViewTitleVariants = [empty]
    template.userInfo =
      items
      .removeDuplicates()
      .sink { [weak self, weak template] items in
        guard let self, let template else { return }
        let items = Array(items.prefix(CPListTemplate.maximumItemCount))
        let rows = items.map { row(self, $0) }
        template.updateSections([CPListSection(items: rows)])
        guard let cover else { return }
        images.loadCovers(
          zip(items, rows).map { .row($1, albumId: cover($0)) }, size: CarPlayImages.rowSize)
      }
    return template
  }

  /// An album that opens; "Artist · Year" unless `detail` says otherwise.
  /// Its cover comes from the list's loader.
  private func albumRow(_ album: Album, detail: String? = nil) -> CPListItem {
    let item = CPListItem(
      text: album.name,
      detailText: detail
        ?? (album.minYear > 0 ? "\(album.albumArtist) · \(album.minYear)" : album.albumArtist),
      image: images.tile(Glyph.album, size: CarPlayImages.rowSize))
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      self?.openAlbum(album)
      completion()
    }
    return item
  }

  private func artistRow(_ artist: Artist) -> CPListItem {
    let item = CPListItem(
      text: artist.name, detailText: MenuTarget.artist(artist).subtitle,
      image: images.tile(Glyph.artist, round: true, size: CarPlayImages.rowSize))
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      self?.openArtist(artist)
      completion()
    }
    return item
  }

  private func playlistRow(_ playlist: Playlist) -> CPListItem {
    let item = CPListItem(
      text: playlist.name, detailText: playlist.comment.isEmpty ? "Playlist" : playlist.comment,
      image: images.tile(Glyph.playlist, size: CarPlayImages.rowSize))
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in
      self?.openPlaylist(playlist)
      completion()
    }
    return item
  }

  private func radioRow(_ radio: Radio) -> CPListItem {
    let item = CPListItem(
      text: radio.name, detailText: "Internet radio",
      image: images.tile(Glyph.radio, round: true, size: CarPlayImages.rowSize))
    item.handler = { [weak self] _, completion in
      self?.play(radio)
      completion()
    }
    return item
  }

  private func tile(for target: MenuTarget, size: CGSize) -> UIImage {
    switch target {
    case .album, .song: images.tile(Glyph.album, size: size)
    case .artist: images.tile(Glyph.artist, round: true, size: size)
    case .playlist: images.tile(Glyph.playlist, size: size)
    case .radio: images.tile(Glyph.radio, round: true, size: size)
    }
  }

  // MARK: - Liked

  private static let likedTitle = "Liked"

  func likedTab() -> TabScreen {
    let template = tab(Self.likedTitle, "heart.fill")
    template.emptyViewTitleVariants = ["No liked songs yet"]
    template.emptyViewSubtitleVariants = ["Tap the heart in Now Playing to like a song."]
    let songs = SongListScreen(template: template, controller: self)
    let changes = Publishers.MergeMany(
      albums.$starredSongs.map { _ in }.eraseToAnyPublisher(),
      albums.$albums.map { _ in }.eraseToAnyPublisher(),
      albums.$artists.map { _ in }.eraseToAnyPublisher(),
      StarStore.shared.$stars.map { _ in }.eraseToAnyPublisher(),
      reachability.map { _ in }.eraseToAnyPublisher())
    return TabScreen(
      template: template,
      sections: { [unowned self] in likedSections(songs) },
      changes: changes.eraseToAnyPublisher(),
      selected: { [unowned self] in albums.fetchStarredSongs() })
  }

  /// Shuffle, the liked songs, then the liked albums and artists, as many as
  /// the list shows.
  private func likedSections(_ screen: SongListScreen) -> [CPListSection] {
    let songs = app.likedSongs
    let size = CarPlayImages.rowSize
    var room = CPListTemplate.maximumItemCount
    var sections: [CPListSection] = []
    if !songs.isEmpty {
      // Offline only the songs on the phone play.
      let local =
        ConnectivityMonitor.shared.canReachServer ? nil : DownloadStore.localMediaFileIds()
      let playable = local.map { local in songs.filter { local.contains($0.playbackID) } } ?? songs
      let shuffle = CPListItem(
        text: "Shuffle Liked Songs", detailText: counted(playable.count, "song"),
        image: images.tile("shuffle", size: size))
      shuffle.handler = { [weak self] _, completion in
        if self?.player.shuffleItem(item: SongCollection.liked(playable)) == true {
          self?.showNowPlaying()
        }
        completion()
      }
      sections.append(CPListSection(items: [shuffle]))
      room -= 1
    }
    let songSection = screen.songSection(
      SongCollection.liked(songs), header: "Songs", limit: room)
    if !songSection.items.isEmpty { sections.append(songSection) }
    room -= songSection.items.count
    let likedAlbums = app.likedAlbums.prefix(max(room, 0))
    room -= likedAlbums.count
    let likedArtists = app.likedArtists.prefix(max(room, 0))
    if !likedAlbums.isEmpty {
      let rows = likedAlbums.map { albumRow($0) }
      sections.append(CPListSection(items: rows, header: "Albums", sectionIndexTitle: nil))
      images.loadCovers(zip(likedAlbums, rows).map { .row($1, albumId: $0.id) }, size: size)
    }
    if !likedArtists.isEmpty {
      sections.append(
        CPListSection(
          items: likedArtists.map(artistRow), header: "Artists", sectionIndexTitle: nil))
    }
    return sections
  }

  // MARK: - Downloads

  func downloadsTab() -> TabScreen {
    let template = tab("Downloads", "arrow.down.circle.fill")
    template.emptyViewTitleVariants = ["Download an album to play it without a connection."]
    let session = DownloadSession.shared
    let albums = albums
    albums.fetchDownloadedAlbums()
    // An album being downloaded shows up with its first song.
    session.downloadFinished
      .sink { id in
        if !albums.downloadedAlbums.contains(where: { $0.id == id }) {
          albums.fetchDownloadedAlbums()
        }
      }
      .store(in: &subscriptions)
    session.downloadsRemoved
      .sink { albums.fetchDownloadedAlbums() }
      .store(in: &subscriptions)
    // The rows of the albums downloading, by id, for their progress.
    var downloading: [String: CPListItem] = [:]
    session.$jobs
      .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
      // Published values are set after their subscribers hear of them.
      .receive(on: DispatchQueue.main)
      .sink { _ in
        for (id, item) in downloading { item.setDetailText(Self.downloadingText(id)) }
      }
      .store(in: &subscriptions)
    // Selecting the tab picks up songs cached since.
    let reload = PassthroughSubject<Void, Never>()
    let changes = Publishers.MergeMany(
      albums.$downloadedAlbums.map { _ in }.eraseToAnyPublisher(),
      session.downloadFinished.map { _ in }.eraseToAnyPublisher(),
      session.downloadsRemoved.eraseToAnyPublisher(),
      // Whether each collection still downloads or failed.
      session.$jobs
        .map { jobs in
          Dictionary(grouping: jobs, by: \.collectionId).mapValues { $0.contains { !$0.failed } }
        }
        .removeDuplicates()
        .map { _ in }
        .eraseToAnyPublisher(),
      reload.eraseToAnyPublisher())
    return TabScreen(
      template: template,
      sections: { [unowned self] in downloadsSections(downloading: &downloading) },
      changes: changes.eraseToAnyPublisher(),
      selected: { reload.send() })
  }

  /// The cached songs, then each downloaded album or playlist with its songs,
  /// progress or failure. Downloads start and retry on the phone only.
  private func downloadsSections(downloading: inout [String: CPListItem]) -> [CPListSection] {
    let session = DownloadSession.shared
    let size = CarPlayImages.rowSize
    var rows: [CPListItem] = []
    let cached = StreamCacheManager.shared.getCachedSongs()
    if !cached.isEmpty {
      let item = CPListItem(
        text: "Cached", detailText: counted(cached.count, "song"),
        image: images.tile(Glyph.playlist, size: size),
        accessoryImage: images.status("checkmark.circle.fill", color: .floDownloaded),
        accessoryType: .none)
      item.handler = { [weak self] _, completion in
        self?.openCached()
        completion()
      }
      rows.append(item)
    }
    let downloaded = albums.downloadedAlbums.prefix(CPListTemplate.maximumItemCount - rows.count)
    downloading = [:]
    let albumRows = downloaded.map { album in
      let isDownloading = session.isDownloading(collectionId: album.id)
      let detail: String
      let status: UIImage?
      if isDownloading {
        (detail, status) = (Self.downloadingText(album.id), nil)
      } else if session.hasFailed(collectionId: album.id) {
        detail = "Download failed · retry on iPhone"
        status = images.status("exclamationmark.circle.fill", color: .floDestructive)
      } else {
        detail = counted(DownloadStore.downloadedMediaFileIds(collectionId: album.id).count, "song")
        status = images.status("checkmark.circle.fill", color: .floDownloaded)
      }
      let item = albumRow(album, detail: detail)
      item.accessoryType = .none
      item.setAccessoryImage(status)
      if isDownloading { downloading[album.id] = item }
      return item
    }
    images.loadCovers(zip(downloaded, albumRows).map { .row($1, albumId: $0.id) }, size: size)
    rows += albumRows
    return rows.isEmpty ? [] : [CPListSection(items: rows)]
  }

  private static func downloadingText(_ collectionId: String) -> String {
    "Downloading · \(Int(DownloadSession.shared.progress(collectionId: collectionId) * 100))%"
  }

  // MARK: - Pushed screens

  func openAlbum(_ album: Album) {
    push(SongListScreen.album(album, controller: self))
  }

  /// The album of a song in the queue: from the library or the downloads,
  /// else made of what the queue knows of it.
  func openAlbum(id: String) {
    Task { [weak self] in
      guard let self else { return }
      let library = await albums.loadedOrCached(albums.albums, .albums)
      let entry = player.queue.first { $0.albumId == id }
      openAlbum(
        (albums.downloadedAlbums + library).first { $0.id == id }
          ?? Album(
            id: id, name: entry?.albumName ?? "", albumArtist: entry?.artistName ?? "",
            artist: entry?.artistName ?? ""))
    }
  }

  func openPlaylist(_ playlist: Playlist) {
    push(SongListScreen.playlist(playlist, controller: self))
  }

  /// Artist Radio and Top Songs, then the artist's albums, newest first.
  func openArtist(_ artist: Artist) {
    let size = CarPlayImages.rowSize
    let template = CPListTemplate(title: artist.name, sections: [])
    let radio = CPListItem(
      text: "Artist Radio", detailText: "Similar songs, starting with \(artist.name)",
      image: images.tile(Glyph.radio, round: true, size: size))
    radio.handler = { [weak self] _, completion in
      let player = self?.player
      Task {
        // Holds the completion until the radio plays or has nothing to play.
        if await player?.playArtistRadio(id: artist.id, name: artist.name) == true {
          self?.showNowPlaying()
        }
        completion()
      }
    }
    // Top songs online, else the artist's songs on the phone, as Siri plays
    // an artist.
    let topSongs = CPListItem(
      text: "Top Songs", detailText: nil, image: images.tile(Glyph.playlist, size: size))
    topSongs.handler = { [weak self] _, completion in
      let player = self?.player
      Task {
        // Holds the completion until the songs play or none were found.
        if await player?.playArtist(id: artist.id, name: artist.name) == true {
          self?.showNowPlaying()
        }
        completion()
      }
    }
    if ConnectivityMonitor.shared.canReachServer {
      Task { [weak topSongs] in
        guard let songs = try? await RadioService.shared.getTopSongs(artistId: artist.id),
          !songs.isEmpty
        else { return }
        topSongs?.setDetailText(counted(songs.count, "song"))
      }
    }
    let plays = CPListSection(items: [radio, topSongs])
    template.updateSections([plays])
    albums.fetchAlbumsByArtist(id: artist.id)
    let albums = albums
    template.userInfo =
      albums.objectWillChange
      .debounce(for: Self.settle, scheduler: DispatchQueue.main)
      // Albums loaded a moment ago for this artist are not asked for again.
      .prepend(())
      .map { albums.albums(byArtist: artist.id) }
      .removeDuplicates()
      .sink { [weak self, weak template] artistAlbums in
        guard let self, let template, !artistAlbums.isEmpty else { return }
        let shown = Array(
          artistAlbums.prefix(CPListTemplate.maximumItemCount - plays.items.count))
        let rows = shown.map { self.albumRow($0, detail: $0.minYear > 0 ? String($0.minYear) : "") }
        template.updateSections([
          plays, CPListSection(items: rows, header: "Albums", sectionIndexTitle: nil),
        ])
        images.loadCovers(zip(shown, rows).map { .row($1, albumId: $0.id) }, size: size)
      }
    push(template)
  }

  func openCached() {
    push(SongListScreen.cached(controller: self))
  }

  func openUpNext() {
    push(SongListScreen.upNext(controller: self))
  }

  // MARK: - Helpers

  /// Plays the station, unless streaming is off on cellular.
  private func play(_ radio: Radio) {
    if app.isRadioBlocked {
      presentStreamingBlocked()
    } else if player.playRadioItem(radio: radio) {
      showNowPlaying()
    }
  }

  private func tab(_ title: String, _ symbol: String) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.tabTitle = title
    template.tabImage = UIImage(systemName: symbol)
    return template
  }
}
