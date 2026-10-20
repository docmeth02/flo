//
//  CarPlaySongList.swift
//  Ownwave
//

import CarPlay
import Combine

/// A pushed list of songs: an album, a playlist, the cached songs or Up
/// Next, and the Liked tab's songs. The playing song's row shows it while
/// the list is on screen, and without the server the songs with no copy on
/// the phone are disabled. Its subscriptions end with it.
@MainActor final class SongListScreen {
  let template: CPListTemplate

  /// A song row by the id the queue uses; `marksPlaying` is false for Up
  /// Next's queued rows, since a song queued twice plays only once.
  private struct Row {
    let id: String
    let item: CPListItem
    var marksPlaying = true
  }

  private weak var controller: CarPlayController?
  private var rows: [Row] = []
  private var subscriptions = Set<AnyCancellable>()

  /// A list over `template`, which the Liked tab brings along.
  init(template: CPListTemplate, controller: CarPlayController) {
    self.template = template
    self.controller = controller
    observePlaying()
    observeReachability()
  }

  convenience init(title: String, controller: CarPlayController) {
    self.init(template: CPListTemplate(title: title, sections: []), controller: controller)
  }

  /// The album's songs as the phone loads them: the downloaded ones at once,
  /// then the server's list. A downloaded playlist opened as an album loads
  /// as a playlist.
  static func album(_ album: Album, controller: CarPlayController) -> SongListScreen {
    let screen = SongListScreen(title: album.name, controller: controller)
    screen.load(controller.albums.loadSongs(of: album), numbered: !album.isPlaylist) { songs in
      var loaded = album
      loaded.songs = songs
      return loaded
    }
    return screen
  }

  /// The playlist plays as an album, so its songs keep it as their origin.
  static func playlist(_ playlist: Playlist, controller: CarPlayController) -> SongListScreen {
    let screen = SongListScreen(title: playlist.name, controller: controller)
    screen.load(controller.albums.loadSongs(of: playlist), numbered: false) { songs in
      var loaded = playlist
      loaded.songs = songs
      return Album(from: loaded)
    }
    return screen
  }

  /// The songs in the stream cache, most recently played first.
  static func cached(controller: CarPlayController) -> SongListScreen {
    let screen = SongListScreen(title: "Cached", controller: controller)
    let songs = StreamCacheManager.shared.getCachedSongs()
    screen.template.updateSections([screen.songSection(SongCollection.cached(songs))])
    return screen
  }

  /// The playing song, then the rest of the play order under its source.
  static func upNext(controller: CarPlayController) -> SongListScreen {
    let screen = SongListScreen(title: "Up Next", controller: controller)
    screen.template.emptyViewTitleVariants = ["Nothing up next."]
    screen.showUpNext()
    let player = controller.player
    Publishers.CombineLatest(player.$queue, player.$activeQueueIdx)
      .dropFirst()
      .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
      .sink { [weak screen] _ in screen?.showUpNext() }
      .store(in: &screen.subscriptions)
    return screen
  }

  // MARK: - Rows

  /// One row per song of `collection`, at most `limit` or as many as a list
  /// shows; a tap plays the collection from that song. Numbered rows (an
  /// album's) show the track number and the length, the others the cover
  /// and the artist.
  func songSection(
    _ collection: some Playable, header: String? = nil, numbered: Bool = false,
    limit: Int? = nil
  ) -> CPListSection {
    guard let controller else { return CPListSection(items: []) }
    let images = controller.images
    let size = CarPlayImages.rowSize
    var covers: [CarPlayImages.Cover] = []
    rows = collection.songs.prefix(limit ?? CPListTemplate.maximumItemCount).enumerated().map {
      index, song in
      let item: CPListItem
      if numbered {
        item = CPListItem(
          text: song.title, detailText: song.duration.minuteSecond,
          image: song.trackNumber > 0 ? images.number(song.trackNumber, size: size) : nil)
      } else {
        item = CPListItem(
          text: song.title, detailText: song.artist, image: images.tile(Glyph.album, size: size))
        covers.append(.row(item, albumId: song.albumId))
      }
      item.playingIndicatorLocation = .trailing
      item.handler = { [weak controller] _, completion in
        if controller?.player.playItem(item: collection, startingAt: index) == true {
          controller?.showNowPlaying()
        }
        completion()
      }
      return Row(id: song.playbackID, item: item)
    }
    images.loadCovers(covers, size: size)
    updatePlaying()
    updateEnabled()
    return CPListSection(items: rows.map(\.item), header: header, sectionIndexTitle: nil)
  }

  /// Shows each list `stream` yields under a Shuffle row; `playable` makes
  /// the album the player takes of the songs.
  private func load(
    _ stream: AsyncStream<[Song]>, numbered: Bool, as playable: @escaping ([Song]) -> Album
  ) {
    template.showsSpinnerWhileEmpty = true
    let task = Task { [weak self] in
      for await songs in stream {
        self?.show(playable(songs), numbered: numbered)
      }
      guard let self else { return }
      template.showsSpinnerWhileEmpty = false
      if !ConnectivityMonitor.shared.canReachServer {
        template.emptyViewTitleVariants = ["Not available offline"]
      }
    }
    subscriptions.insert(AnyCancellable(task.cancel))
  }

  private func show(_ collection: Album, numbered: Bool) {
    guard let controller, !collection.songs.isEmpty else { return }
    let shuffle = CPListItem(
      text: "Shuffle", detailText: collection.songs.countAndLength,
      image: controller.images.tile("shuffle", size: CarPlayImages.rowSize))
    shuffle.handler = { [weak controller] _, completion in
      if controller?.player.shuffleItem(item: collection) == true { controller?.showNowPlaying() }
      completion()
    }
    let songs = songSection(
      collection, numbered: numbered, limit: CPListTemplate.maximumItemCount - 1)
    template.updateSections([CPListSection(items: [shuffle]), songs])
  }

  private func showUpNext() {
    guard let controller else { return }
    let player = controller.player
    guard let current = player.nowPlaying else {
      rows = []
      return template.updateSections([])
    }
    let images = controller.images
    let size = CarPlayImages.rowSize
    var covers: [CarPlayImages.Cover] = []
    var rows: [Row] = []
    func row(_ entry: QueueEntity, at index: Int, isCurrent: Bool) -> CPListItem {
      let artist = entry.artistName ?? "Unknown"
      let reason = isCurrent ? nil : RecommendationLog.shared.shownReason(for: entry)
      let item = CPListItem(
        text: entry.songName ?? "Unknown",
        detailText: reason.map { "\(artist) · \($0.note)" } ?? artist,
        image: images.tile(Glyph.album, size: size))
      item.playingIndicatorLocation = .trailing
      item.handler = { [weak controller] _, completion in
        // The queue may have changed since the row was built.
        if let player = controller?.player, !isCurrent, player.queue.indices.contains(index),
          player.queue[index] == entry
        {
          player.playFromQueue(idx: index)
        }
        controller?.showNowPlaying()
        completion()
      }
      covers.append(.row(item, albumId: entry.albumId ?? ""))
      rows.append(Row(id: entry.id ?? "", item: item, marksPlaying: isCurrent))
      return item
    }
    let nowPlaying = CPListSection(
      items: [row(current, at: player.activeQueueIdx, isCurrent: true)], header: "Now Playing",
      sectionIndexTitle: nil)
    let queued = player.queue.enumerated().dropFirst(player.activeQueueIdx + 1)
      .prefix(CPListTemplate.maximumItemCount - 1)
      .map { row($0.element, at: $0.offset, isCurrent: false) }
    let source = player.upNextSource
    self.rows = rows
    images.loadCovers(covers, size: size)
    updatePlaying()
    updateEnabled()
    template.updateSections(
      queued.isEmpty
        ? [nowPlaying]
        : [
          nowPlaying,
          CPListSection(
            items: queued, header: source.isEmpty ? nil : source, sectionIndexTitle: nil),
        ])
  }

  // MARK: - Playing and offline state

  /// Follows the player while the list is on screen, the playing row's
  /// progress at most once a second; a hidden list does nothing.
  private func observePlaying() {
    guard let controller else { return }
    let player = controller.player
    let template = template
    controller.$visible
      .map { [weak controller] visible in
        // A tab's list shows while the tab bar is on top and it is selected.
        visible === template
          || (visible != nil && visible === controller?.tabBar
            && controller?.tabBar.selectedTemplate === template)
      }
      .removeDuplicates()
      .map { shown -> AnyPublisher<Void, Never> in
        guard shown else { return Empty().eraseToAnyPublisher() }
        return Publishers.Merge(
          Publishers.CombineLatest3(player.$queue, player.$activeQueueIdx, player.$isPlaying)
            .map { _ in },
          player.clock.$progress
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .map { _ in }
        )
        .eraseToAnyPublisher()
      }
      .switchToLatest()
      // Published values are set after their subscribers hear of them.
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.updatePlaying() }
      .store(in: &subscriptions)
  }

  private func observeReachability() {
    controller?.reachability
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateEnabled() }
      .store(in: &subscriptions)
  }

  private func updatePlaying() {
    guard let player = controller?.player else { return }
    let current = player.nowPlayingId
    let progress = CGFloat(player.clock.clampedProgress)
    for row in rows where row.marksPlaying {
      let isCurrent = row.id == current
      let playing = isCurrent && player.isPlaying
      if row.item.isPlaying != playing { row.item.isPlaying = playing }
      let rowProgress = isCurrent ? progress : 0
      if row.item.playbackProgress != rowProgress { row.item.playbackProgress = rowProgress }
    }
  }

  /// Without the server only songs downloaded or cached on the phone play.
  private func updateEnabled() {
    let local =
      ConnectivityMonitor.shared.canReachServer ? nil : DownloadStore.localMediaFileIds()
    for row in rows {
      let enabled = local?.contains(row.id) ?? true
      if row.item.isEnabled != enabled { row.item.isEnabled = enabled }
    }
  }
}
