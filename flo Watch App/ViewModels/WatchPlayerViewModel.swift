//
//  WatchPlayerViewModel.swift
//  flo Watch App
//

import AVFoundation
import Combine
import MediaPlayer
import WatchKit

class WatchPlayerViewModel: ObservableObject {
  private(set) var player: AVPlayer? {
    didSet { observeBuffering() }
  }
  private var playerItem: AVPlayerItem?
  private var timeObserverToken: Any?

  @Published var queue: [QueueEntity] = []
  @Published var playbackMode = PlaybackMode.defaultPlayback

  @Published var activeQueueIdx: Int = 0

  @Published var isMediaFailed: Bool = false
  @Published var isMediaLoading: Bool = false
  /// AVPlayer is waiting for data before it can play, as at the start of a
  /// song after a skip; isMediaLoading only covers the time until the item
  /// exists.
  @Published private(set) var isBuffering = false
  @Published var isShuffling: Bool = false
  @Published var isPlaying: Bool = false

  @Published var progress: Double = 0.0

  @Published var currentTimeString: String = "00:00"
  @Published var totalTimeString: String = "00:00"

  @Published var isStarred: Bool = false
  // Bumped by a song change and by every tap on the heart; a starred lookup
  // or a failed toggle from before must not overwrite the newer state.
  private var starGeneration = 0

  private var isLocallySaved: Bool = false
  private var isFinished: Bool = false
  private var isAutoContinuing: Bool = false
  private var totalDuration: Double = 0.0
  private var playerItemObservation: AnyCancellable?
  private var bufferingObservation: AnyCancellable?
  private var playbackEndObservation: AnyCancellable?
  private var interruptionObservation = Set<AnyCancellable>()
  private var logoutObservation: AnyCancellable?
  private var unshuffledQueue: [QueueEntity] = []

  private var hasTriggeredCache: Bool = false
  // Audible playback of the current item; unlike the playhead position,
  // seeking cannot inflate or erase it.
  private var secondsListened: Double = 0
  private var lastObservedTime: Double = 0
  private var playGeneration: Int = 0
  private var consecutiveFailures: Int = 0
  private static let maxConsecutiveFailures = 3
  // Long enough for a slow cellular start, short enough not to feel stuck.
  private static let loadTimeout: TimeInterval = 20
  private var loadWatchdog: DispatchWorkItem?
  private var playbackFailureObservation: AnyCancellable?
  private var needsNowPlayingAnnouncement = false
  // The song whose failed item Play already reloaded once; a second failure
  // goes through the capped skip instead of reloading again.
  private var reloadedFailedTrackId: String?
  private var radioURL: URL?
  // The item whose failure was already counted; KVO, the failure notification
  // and Play can all report the same one.
  private weak var countedFailedItem: AVPlayerItem?
  // Track seconds at the current item's time 0; above 0 only for a transcode
  // the server started mid-track.
  private var streamOffset: Double = 0
  // Where Play starts the song while no item is attached (restored queue,
  // stop, a load still waiting for its stream source).
  private var pendingStartPosition: Double = 0
  private var currentSourceIsRemote = false
  private var currentSourceIsTranscoded = false
  // Listening time at the last mid-song resume; a stream that breaks again
  // before 30 s more were heard is skipped rather than resumed over and over.
  // Listening time, not position: a seek back must not block the next resume.
  private var resumedAtListened: Double?
  // The song whose stream was asked for a second time after failing before it
  // got going; unlike reloadedFailedTrackId it survives the new item becoming
  // ready, so a stream that keeps dying right after its start is not reloaded
  // forever.
  private var restartedTrackId: String?
  // Bumped whenever the item is detached; a stream source resolved for an
  // older load is dropped. playGeneration moves with play/pause and cannot
  // tell.
  private var loadGeneration = 0
  // The listening session Keep Playing continues: when it began, the last
  // song heard out (never a skip) and the genres the first such song set.
  private var sessionStartedAt: Date?
  private var lastPlaybackAt: Date?
  private var lastAcceptedSong: (id: String, artist: String, albumId: String)?
  private var anchorGenres: Set<String> = []
  private static let sessionTimeout: TimeInterval = 30 * 60
  private var ratingObservation: AnyCancellable?
  /// Bumped whenever the user starts something new; a mix built in the
  /// meantime is stale.
  private(set) var startGeneration = 0

  var nowPlaying: QueueEntity {
    return self.queue[self.activeQueueIdx]
  }

  var isLiveRadio: Bool {
    guard hasNowPlaying() else { return false }
    return nowPlaying.duration.isInfinite || nowPlaying.duration.isNaN
  }

  init() {
    self.player = AVPlayer()
    // Property observers do not run for assignments in init.
    observeBuffering()
    self.observeInterruptionNotifications()

    logoutObservation = NotificationCenter.default.publisher(for: .didLogout)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.clearForLogout() }

    let lastPlayData = PlaybackService.shared.getQueue()
    let queueActiveIdx = UserDefaultsManager.queueActiveIdx

    // A radio station stays in the stored queue while it plays (its object
    // must stay alive for isLiveRadio and the metadata), but a live stream is
    // not something to resume at launch.
    let isRadioQueue = lastPlayData.first.map { !$0.duration.isFinite } ?? false

    if !lastPlayData.isEmpty && queueActiveIdx < lastPlayData.count && !isRadioQueue {
      self.progress = UserDefaultsManager.nowPlayingProgress
      self.playbackMode = UserDefaultsManager.playbackMode
      // A queue shuffled in the player goes on in the order it was heard in;
      // the stored queue keeps the original order. Read before addToQueue
      // forgets it.
      let order = (UserDefaults.standard.array(forKey: Self.shuffleOrderKey) as? [Int])
        .flatMap { $0.sorted() == Array(lastPlayData.indices) ? $0 : nil }
      self.addToQueue(
        idx: order?.firstIndex(of: queueActiveIdx) ?? queueActiveIdx,
        item: order?.map { lastPlayData[$0] } ?? lastPlayData, playAudio: false)
      if order != nil {
        self.unshuffledQueue = lastPlayData
        self.isShuffling = true
        self.persistActiveIndex()
        self.persistShuffleOrder()
      }
      // A song that already counted must not count again after a relaunch,
      // and one that did not yet keeps the listening time it had.
      self.isLocallySaved = UserDefaultsManager.nowPlayingQualified
      self.secondsListened = UserDefaultsManager.nowPlayingListened
      debugLog(
        "restored \(self.nowPlaying.id ?? "") qualified=\(self.isLocallySaved) "
          + "listened=\(Int(self.secondsListened))s")
    } else {
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      UserDefaults.standard.removeObject(forKey: Self.shuffleOrderKey)
      PlaybackService.shared.clearQueue()
    }

    self.setupRemoteCommandCenter()
    // Like and dislike follow the rating, wherever it was changed.
    Task { @MainActor [weak self] in
      self?.ratingObservation = RatingStore.shared.$ratings
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateRatingCommands() }
    }

    #if DEBUG
      runDebugLaunchActions()
    #endif
  }

  func observeInterruptionNotifications() {
    NotificationCenter.default
      .publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        self?.handleInterruptionNotification(notification)
      }
      .store(in: &interruptionObservation)

    // The system pauses the player when the headphones go away; the controls
    // and the server have to follow, or the next tap pauses again.
    NotificationCenter.default
      .publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let self, self.isPlaying,
          let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable
        else { return }
        self.pause()
      }
      .store(in: &interruptionObservation)
  }

  func handleInterruptionNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? Int,
      let type = AVAudioSession.InterruptionType(rawValue: UInt(typeValue))
    else {
      return
    }

    switch type {
    case .began:
      // Through pause() so a pending skip or Keep Playing mix does not start
      // playback during the call.
      self.pause()
    case .ended:
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? Int {
        let options = AVAudioSession.InterruptionOptions(rawValue: UInt(optionsValue))
        if options.contains(.shouldResume) {
          self.play()
        }
      }
    @unknown default:
      break
    }
  }

  /// Tracks the current item's loading state for both songs and radio.
  private func observeItemStatus(trackId: String?) {
    let item = playerItem
    playerItemObservation = playerItem?.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] status in
        // A late report for a replaced item must not touch the new one's flags.
        guard let self = self, let item, item === self.playerItem else { return }
        switch status {
        case .readyToPlay:
          self.consecutiveFailures = 0
          self.reloadedFailedTrackId = nil
          self.loadWatchdog?.cancel()
          // Waiting for the first data shows as buffering from here on.
          self.isMediaLoading = false
          self.isMediaFailed = false
        case .failed:
          self.isMediaLoading = false
          self.handleStreamFailure(trackId: trackId, item: item)
        case .unknown:
          // Every new item starts here; it is still loading.
          break
        @unknown default:
          self.isMediaLoading = true
        }
      }
  }

  private func observeBuffering() {
    bufferingObservation = player?.publisher(for: \.timeControlStatus)
      .map { $0 == .waitingToPlayAtSpecifiedRate }
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        debugLog("buffering \($0)")
        self?.isBuffering = $0
      }
  }

  /// A player whose item failed can end up failed itself, and a failed
  /// AVPlayer refuses every later item; start over with a fresh one. Callers
  /// have already removed the time observer from the old player.
  private func replacePlayerIfFailed() {
    guard let old = player, old.status == .failed else { return }
    player = AVPlayer()
    debugLog("replaced failed player")
  }

  /// Reconnects a failed radio station to its own stream URL; the song
  /// stream endpoint knows nothing about stations.
  private func reloadRadioItem() {
    guard let radioURL = radioURL else { return }
    tearDownItemObservers()
    replacePlayerIfFailed()
    playerItem = AVPlayerItem(url: radioURL)
    player?.replaceCurrentItem(with: playerItem)
    observeItemStatus(trackId: hasNowPlaying() ? nowPlaying.id : nil)
    addPeriodicTimeObserver()
  }

  /// Detaches every observer tied to the current item.
  private func tearDownItemObservers() {
    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }
    playerItemObservation?.cancel()
    playbackEndObservation?.cancel()
    playbackEndObservation = nil
    playbackFailureObservation = nil
    loadWatchdog?.cancel()
  }

  /// Removes the current item and its observers; a stream source still being
  /// resolved for it is dropped when it arrives.
  private func detachItem() {
    loadGeneration += 1
    tearDownItemObservers()
    player?.replaceCurrentItem(with: nil)
    playerItem = nil
    streamOffset = 0
  }

  /// Attaches the now playing song's item, starting at `position` seconds of
  /// the track: a transcode is started there by the server, anything else is
  /// seeked there. Remote songs wait for the server's transcode decision.
  private func loadItem(at position: Double) {
    guard queue.indices.contains(activeQueueIdx), !isLiveRadio else { return }
    detachItem()
    replacePlayerIfFailed()
    pendingStartPosition = position
    isMediaLoading = true
    isMediaFailed = false

    let generation = loadGeneration
    let trackId = nowPlaying.id
    let songId = trackId ?? ""

    if let fileURL = AlbumService.shared.localFileURL(mediaFileId: songId) {
      attachItem(
        url: fileURL, trackId: trackId, isRemote: false, isTranscoded: false, offset: 0,
        seekTo: position, endpointName: nil)
      return
    }

    let suffix = nowPlaying.suffix
    Task { @MainActor [weak self] in
      let source = await AlbumService.shared.resolveStreamSource(
        songId: songId, originalSuffix: suffix, offset: Int(position))
      guard let self, self.loadGeneration == generation,
        self.queue.indices.contains(self.activeQueueIdx), self.nowPlaying.id == trackId,
        let url = URL(string: source.url)
      else { return }

      let startsAtOffset = source.isTranscoded && position > 0
      self.attachItem(
        url: url, trackId: trackId, isRemote: true, isTranscoded: source.isTranscoded,
        offset: startsAtOffset ? floor(position) : 0, seekTo: startsAtOffset ? nil : position,
        endpointName: (source.endpoint as NSString).lastPathComponent)
    }
  }

  private func attachItem(
    url: URL, trackId: String?, isRemote: Bool, isTranscoded: Bool, offset: Double,
    seekTo position: Double?, endpointName: String?
  ) {
    let item = AVPlayerItem(url: url)
    playerItem = item
    player?.replaceCurrentItem(with: item)
    streamOffset = offset
    currentSourceIsRemote = isRemote
    currentSourceIsTranscoded = isTranscoded

    observeItemStatus(trackId: trackId)

    // A server that never answers leaves the item loading forever without
    // reporting .failed, and a stream can also break mid-song; the first is
    // caught by the load watchdog, the second resumes or skips.
    loadWatchdog?.cancel()
    playbackFailureObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] _ in self?.handleStreamFailure(trackId: trackId, item: item) }

    // Fallback advance for items whose reported duration is off (VBR, missing
    // metadata): if the periodic check misses the end, the player item itself
    // tells us. The observation is per-item, so a track advanced by the
    // periodic check never double-fires here.
    playbackEndObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] _ in
        guard let self else { return }
        // A transcode whose encoder died ends cleanly, far short of the song.
        if self.currentSourceIsTranscoded, self.totalDuration.isFinite,
          self.lastObservedTime < self.totalDuration - 10
        {
          self.handleStreamFailure(trackId: trackId, item: item)
          return
        }
        self.qualifyIfDue()
        self.acceptNowPlaying()
        self.nextSong()
        UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      }

    if let position, position > 0 {
      player?.seek(to: CMTime(seconds: position, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }
    addPeriodicTimeObserver()

    if isPlaying {
      player?.play()
      armLoadWatchdog()
    }
    // Re-anchors the system's elapsed time clock.
    updateNowPlayingInfo(progress: progress, rate: isPlaying ? 1.0 : 0.0)

    // AVPlayer loads bypass the request log's Alamofire monitor.
    if let endpointName {
      RequestLog.shared.note(
        "player \(endpointName) offset=\(Int(offset))\(isTranscoded ? " transcode" : "")")
    }
  }

  /// A stream that breaks mid-song resumes where it was instead of skipping
  /// ahead: a transcode restarts there, direct play seeks there. Failing to
  /// load, or breaking again within 30 s of the last resume, counts as failed.
  private func handleStreamFailure(trackId: String?, item: AVPlayerItem?) {
    // KVO and the failure notification can both report the same item, and a
    // late report can arrive for an item already replaced.
    guard let item, item === playerItem else { return }
    // The load watchdog already counted this item and scheduled the skip.
    guard item !== countedFailedItem else { return }
    let isNowPlaying = queue.indices.contains(activeQueueIdx) && nowPlaying.id == trackId
    // The server may no longer accept the decision's token.
    if isNowPlaying, !isLiveRadio, currentSourceIsRemote, let trackId {
      AlbumService.shared.forgetTranscodeDecision(songId: trackId)
    }

    // A song that never got going is asked for once more: the server rejects a
    // decision's token after a rescan touched the file. Paused, the dead item
    // is dropped so that Play loads the song again where it was; its status
    // may still read ready, which play() would otherwise trust.
    guard isNowPlaying, !isLiveRadio, currentSourceIsRemote, isPlaying, lastObservedTime > 5,
      resumedAtListened.map({ secondsListened - $0 >= 30 }) ?? true
    else {
      if isNowPlaying, !isLiveRadio, currentSourceIsRemote, !isPlaying {
        if lastObservedTime > 5 { pendingStartPosition = floor(lastObservedTime) }
        detachItem()
        isMediaFailed = true
        return
      }
      if isNowPlaying, !isLiveRadio, currentSourceIsRemote, lastObservedTime <= 5,
        restartedTrackId != trackId
      {
        restartedTrackId = trackId
        loadItem(at: pendingStartPosition)
        return
      }
      isMediaFailed = true
      skipFailedTrack(trackId: trackId)
      return
    }

    let position = floor(lastObservedTime)
    resumedAtListened = secondsListened
    debugLog("stream broke at \(position) s, resuming: \(trackId ?? "")")
    loadItem(at: position)
  }

  /// Treats an item that is still not ready after `loadTimeout` of playing as
  /// failed. A user who paused in the meantime is left alone.
  private func armLoadWatchdog() {
    loadWatchdog?.cancel()
    guard let item = playerItem, item.status != .readyToPlay, !isLiveRadio else { return }

    let trackId = hasNowPlaying() ? nowPlaying.id : nil
    let watchdog = DispatchWorkItem { [weak self, weak item] in
      guard let self = self, self.isPlaying, let item = item, self.playerItem === item,
        item.status != .readyToPlay
      else { return }
      self.player?.pause()
      self.skipFailedTrack(trackId: trackId)
    }
    loadWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: watchdog)
  }

  /// A failed stream (deleted file, transcoder error, corrupt cache) never
  /// reaches its end, so nothing would advance and playback would sit silent.
  /// Skip ahead after a moment, but stop after a few failures in a row so an
  /// unreachable server does not burn through the whole queue.
  private func skipFailedTrack(trackId: String?) {
    loadWatchdog?.cancel()
    // Paused playback stays paused; pressing Play reloads the failed item.
    guard isPlaying, queue.indices.contains(activeQueueIdx), nowPlaying.id == trackId,
      !isLiveRadio, playerItem == nil || playerItem !== countedFailedItem
    else {
      return
    }
    countedFailedItem = playerItem
    consecutiveFailures += 1
    debugLog(
      "stream failed: \(trackId ?? "") (\(consecutiveFailures) in a row) "
        + "item=\(String(describing: playerItem?.status.rawValue)) "
        + "error=\(String(describing: playerItem?.error))")
    guard consecutiveFailures <= Self.maxConsecutiveFailures else {
      // Give up: nothing is playing any more, and the UI must say so.
      isPlaying = false
      isMediaLoading = false
      player?.pause()
      updateNowPlayingInfo(progress: progress, rate: 0.0)
      // Several songs in a row failing on a reachable server usually means the
      // server rebuilt its library and the cached song ids are gone.
      if consecutiveFailures == Self.maxConsecutiveFailures + 1,
        ConnectivityMonitor.shared.isServerReachable
      {
        SmartPlaybackService.shared.refreshSongLibrary()
      }
      return
    }

    let generation = playGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      // A pause or play in the meantime means the user took over.
      guard let self = self, self.playGeneration == generation,
        self.queue.indices.contains(self.activeQueueIdx), self.nowPlaying.id == trackId
      else { return }
      self.nextSong()
    }
  }

  /// Stops playback and forgets the queue; its songs belong to the account
  /// that just logged out.
  private func clearForLogout() {
    // No report: the credentials are gone before this runs.
    resetSession()
    playGeneration += 1
    startGeneration += 1
    player?.pause()
    detachItem()

    queue = []
    activeQueueIdx = 0
    unshuffledQueue = []
    isShuffling = false
    persistShuffleOrder()
    isPlaying = false
    progress = 0
    reloadedFailedTrackId = nil

    PlaybackService.shared.clearQueue()
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    Task { @MainActor [weak self] in self?.updateRatingCommands() }
  }

  func addToQueue(idx: Int, item: [QueueEntity], playAudio: Bool = true) {
    // A new queue starts unshuffled; the saved order belongs to the old one.
    self.isShuffling = false
    self.unshuffledQueue = []
    self.persistShuffleOrder()
    self.consecutiveFailures = 0
    self.activeQueueIdx = idx
    self.queue = item
    self.setNowPlaying(playAudio: playAudio)
  }

  func getAlbumCoverArt() -> String {
    return AlbumService.shared.getAlbumCover(
      artistName: self.nowPlaying.artistName ?? "", albumName: self.nowPlaying.albumName ?? "",
      albumId: self.nowPlaying.albumId ?? "", trackId: self.nowPlaying.id ?? "")
  }

  func hasNowPlaying() -> Bool {
    return !self.queue.isEmpty
  }

  func setNowPlaying(playAudio: Bool = true) {
    guard queue.indices.contains(activeQueueIdx) else {
      player?.pause()
      tearDownItemObservers()
      isMediaLoading = false
      isMediaFailed = true
      return
    }

    self.persistActiveIndex()
    self.isLocallySaved = false
    self.hasTriggeredCache = false
    self.secondsListened = 0
    self.lastObservedTime = 0
    self.resumedAtListened = nil
    self.restartedTrackId = nil
    self.reloadedFailedTrackId = nil

    StreamCacheManager.shared.cancelAllInFlight(except: self.nowPlaying.id)
    StreamCacheManager.shared.setCurrentlyPlaying(mediaFileId: self.nowPlaying.id ?? "")

    // The item itself is attached by play(), so a queue restored at launch
    // streams nothing until the user presses Play.
    self.detachItem()
    self.isMediaLoading = false

    // Songs from Subsonic endpoints can carry sampleRate 0, which would make
    // an invalid CMTime and a NaN duration — the end-of-track check would
    // never fire and playback would stall after every song.
    let timescale =
      self.nowPlaying.sampleRate > 0 ? self.nowPlaying.sampleRate : CMTimeScale(NSEC_PER_SEC)
    let duration = CMTime(seconds: self.nowPlaying.duration, preferredTimescale: timescale)
    let playbackDuration = CMTimeGetSeconds(duration)

    self.totalDuration = playbackDuration
    self.totalTimeString = timeString(for: playbackDuration)

    if playAudio {
      self.progress = 0
      // The first observer tick now waits for the stream decision; a kill in
      // between must not restore this song at the previous one's position.
      UserDefaultsManager.nowPlayingProgress = 0
      UserDefaultsManager.nowPlayingQualified = false
      UserDefaultsManager.nowPlayingListened = 0
    }
    self.pendingStartPosition = self.progress * playbackDuration
    self.currentTimeString = timeString(for: self.pendingStartPosition)
    // The first tick after a restore must not count the way to the position.
    self.lastObservedTime = self.pendingStartPosition

    // A queue restored at launch stays paused; telling the server it is
    // playing waits until the user actually plays it.
    // play() announces once the audio session is active, so a route that
    // fails to activate reports nothing.
    self.needsNowPlayingAnnouncement = true
    if playAudio {
      self.play()
    }

    self.initNowPlayingInfo(
      title: self.nowPlaying.songName ?? "",
      artist: self.nowPlaying.artistName ?? "",
      playbackDuration: self.totalDuration)
    // Nothing is attached yet, so the restored position is published here.
    if !playAudio {
      self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
    }

    // Also for a restored queue, so the first tap on the heart is the right way.
    self.loadStarred()
  }

  private func loadStarred() {
    starGeneration += 1
    let generation = starGeneration
    isStarred = false
    guard let songId = nowPlaying.id, !songId.isEmpty else { return }
    AlbumService.shared.isStarred(songId: songId) { [weak self] starred in
      DispatchQueue.main.async {
        guard let self, self.starGeneration == generation else { return }
        self.isStarred = starred
      }
    }
  }

  /// Reports the current song as playing to the server, once per song.
  private func announceNowPlaying() {
    guard needsNowPlayingAnnouncement, queue.indices.contains(activeQueueIdx) else { return }
    needsNowPlayingAnnouncement = false
    // A station is no song the server knows.
    guard !isLiveRadio else { return }

    FloooViewModel.shared.reportPlayback(
      state: .starting, nowPlaying: self.nowPlaying, positionSeconds: self.pendingStartPosition)
  }

  /// Tells the server where the announced song stands; the ViewModel drops a
  /// playing report within 30 s of the last one.
  private func reportPlayback(_ state: PlaybackReportState, at position: Double? = nil) {
    guard !needsNowPlayingAnnouncement, queue.indices.contains(activeQueueIdx), !isLiveRadio
    else { return }
    FloooViewModel.shared.reportPlayback(
      state: state, nowPlaying: nowPlaying,
      positionSeconds: position ?? (playerItem == nil ? pendingStartPosition : lastObservedTime))
  }

  /// Reports the song as stopped before playback moves on, while its entity
  /// is still in the queue; playing it again announces it anew.
  private func reportStopped() {
    reportPlayback(.stopped)
    needsNowPlayingAnnouncement = true
  }

  private func addPeriodicTimeObserver() {
    guard let player = self.player else { return }

    let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    // A callback already queued on main can fire after the track advanced
    // (e.g. via the did-play-to-end fallback); comparing the old track's time
    // against the new track's duration would advance a second time. The item
    // identity check drops those stale callbacks.
    let observedItem = self.playerItem
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self, weak observedItem] time in
      guard let self = self, let observedItem = observedItem,
        self.playerItem === observedItem, time.isNumeric
      else { return }
      let currentTime = self.streamOffset + CMTimeGetSeconds(time)
      let roundedTotalDuration = floor(self.totalDuration)

      if self.totalDuration.isFinite, self.totalDuration > 0 {
        self.progress = currentTime / self.totalDuration
      } else {
        self.progress = 0.0
      }
      self.currentTimeString = timeString(for: currentTime)

      // The observer also fires on seeks and rate changes. Count only small
      // forward steps while playing; a seek jumps further or backwards.
      let step = currentTime - self.lastObservedTime
      // Ticks arrive every second; a larger step is a seek, or a stall whose
      // time was not heard either way.
      if (self.player?.rate ?? 0) > 0, step > 0, step <= 3 {
        self.secondsListened += step
      }
      self.lastObservedTime = currentTime

      // Half an hour without playback ends the listening session.
      if (self.player?.rate ?? 0) > 0 {
        let now = Date()
        if self.sessionStartedAt == nil
          || now.timeIntervalSince(self.lastPlaybackAt ?? .distantPast) > Self.sessionTimeout
        {
          self.resetSession()
          self.sessionStartedAt = now
        }
        self.lastPlaybackAt = now
      }

      UserDefaultsManager.nowPlayingProgress = self.progress
      UserDefaultsManager.nowPlayingListened = self.secondsListened

      if !self.hasTriggeredCache && currentTime >= 10.0 && !self.isLiveRadio {
        self.hasTriggeredCache = true
        if let nextIdx = self.nextQueueIdxForPreCache(),
          let nextId = self.queue[nextIdx].id, !nextId.isEmpty
        {
          AlbumService.shared.prefetchTranscodeDecision(songId: nextId)
          StreamCacheManager.shared.cacheSong(
            mediaFileId: nextId, originalSuffix: self.queue[nextIdx].suffix,
            from: self.queue[nextIdx])
        }
      }

      self.qualifyIfDue()

      if self.totalDuration.isFinite,
        self.totalDuration > 0,
        round(currentTime) >= roundedTotalDuration
      {
        // A song heard to its end was accepted, also when qualification did
        // not run this time (counted before a relaunch, or joined late); a
        // last tick may still owe it the count.
        self.qualifyIfDue()
        self.acceptNowPlaying()
        self.nextSong()
        UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      }
    }
  }

  private func initNowPlayingInfo(
    title: String, artist: String, playbackDuration: Double
  ) {
    // Set title/artist/duration immediately so Now Playing is never empty
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
    nowPlayingInfo[MPMediaItemPropertyTitle] = title
    nowPlayingInfo[MPMediaItemPropertyArtist] = artist
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackDuration
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    Task { @MainActor [weak self] in self?.updateRatingCommands() }

    // Load artwork asynchronously and merge it in
    let albumCoverArt = self.getAlbumCoverArt()
    let currentTrackId = self.queue.indices.contains(self.activeQueueIdx) ? self.nowPlaying.id : nil

    if albumCoverArt.hasPrefix("/") {
      // Local file - load directly
      if let image = UIImage(contentsOfFile: albumCoverArt) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    } else if let albumId = self.queue.indices.contains(self.activeQueueIdx)
      ? self.nowPlaying.albumId : nil
    {
      // Shares the cover cache's single download with the album art views.
      CoverArtCacheManager.shared.coverPath(albumId: albumId) { [weak self] path in
        guard let path, let image = UIImage(contentsOfFile: path) else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

        DispatchQueue.main.async {
          // Only apply artwork if we're still on the same track
          guard let self = self,
                self.queue.indices.contains(self.activeQueueIdx),
                self.nowPlaying.id == currentTrackId else { return }
          var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
          info[MPMediaItemPropertyArtwork] = artwork
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
      }
    }
  }

  func updateNowPlayingInfo(progress: TimeInterval, rate: Float) {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()

    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress * self.totalDuration
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = self.totalDuration
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  private func setupRemoteCommandCenter() {
    let commandCenter = MPRemoteCommandCenter.shared()

    // Remote commands can arrive off the main thread; every handler hops to
    // main before touching playback or published state.
    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [weak self] event in
      guard let self = self else { return .commandFailed }
      DispatchQueue.main.async { self.play() }
      return .success
    }

    commandCenter.pauseCommand.addTarget { [weak self] event in
      guard let self = self else { return .commandFailed }
      DispatchQueue.main.async { self.pause() }
      return .success
    }

    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.nextTrackCommand.addTarget { [weak self] event in
      guard let self = self else { return .commandFailed }
      DispatchQueue.main.async { self.nextSong(userInitiated: true) }
      return .success
    }

    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.addTarget { [weak self] event in
      guard let self = self else { return .commandFailed }
      DispatchQueue.main.async { self.prevSong() }
      return .success
    }

    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent
      else { return .commandFailed }
      let positionTime = event.positionTime
      DispatchQueue.main.async {
        guard !self.isLiveRadio, self.totalDuration > 0 else { return }
        self.seek(to: positionTime / self.totalDuration)
      }
      return .success
    }

    // Like and dislike stand for Boost and Avoid; pressing the active one
    // clears the rating.
    commandCenter.likeCommand.localizedTitle = "Boost"
    commandCenter.likeCommand.localizedShortTitle = "Boost"
    commandCenter.likeCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasNowPlaying() else { return }
        let rating = RatingStore.shared.rating(for: self.nowPlaying.id ?? "")
        self.rateNowPlaying(rating >= 4 ? 0 : 5)
      }
      return .success
    }

    commandCenter.dislikeCommand.localizedTitle = "Avoid in Smart Shuffle"
    commandCenter.dislikeCommand.localizedShortTitle = "Avoid"
    commandCenter.dislikeCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasNowPlaying() else { return }
        let rating = RatingStore.shared.rating(for: self.nowPlaying.id ?? "")
        self.rateNowPlaying((1...2).contains(rating) ? 0 : 1)
      }
      return .success
    }
  }

  /// Rates the now playing song from the rating dialog or the remote like
  /// and dislike; 0 clears the rating.
  @MainActor func rateNowPlaying(_ rating: Int) {
    guard hasNowPlaying(), !isLiveRadio else { return }
    RatingStore.shared.set(rating, for: nowPlaying)
  }

  /// Rates the song the dialog was opened for, which may have ended meanwhile.
  @MainActor func rate(_ rating: Int, playbackID: String) {
    guard !playbackID.isEmpty else { return }
    RatingStore.shared.set(rating, playbackID: playbackID)
  }

  @MainActor private func updateRatingCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()
    let isRateable = hasNowPlaying() && !isLiveRadio
    let rating = isRateable ? RatingStore.shared.rating(for: nowPlaying.id ?? "") : 0
    commandCenter.likeCommand.isEnabled = isRateable
    commandCenter.dislikeCommand.isEnabled = isRateable
    commandCenter.likeCommand.isActive = rating >= 4
    commandCenter.dislikeCommand.isActive = (1...2).contains(rating)
    debugLog(
      "rating commands: rating=\(rating) like=\(commandCenter.likeCommand.isActive) "
        + "dislike=\(commandCenter.dislikeCommand.isActive)")
  }

  func play() {
    // Activate audio session using watchOS async API
    playGeneration += 1
    let gen = playGeneration
    AVAudioSession.sharedInstance().activate(options: []) { [weak self] success, error in
      // The callback arrives off-main; playGeneration is only read or written
      // on the main queue.
      DispatchQueue.main.async {
        guard let self = self, gen == self.playGeneration else { return }
        if let error = error {
          print("Audio session activation failed: \(error)")
          return
        }

        if self.isFinished {
          self.stop()
          self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
        }

        if self.playerItem == nil, self.hasNowPlaying(), !self.isLiveRadio {
          self.isFinished = false
          self.isPlaying = true
          self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
          self.announceNowPlaying()
          self.reportPlayback(.playing)
          self.loadItem(at: self.pendingStartPosition)
          return
        }

        // A failed item cannot play; a fresh one gets one more chance.
        if self.playerItem?.status == .failed, self.hasNowPlaying() {
          let trackId = self.nowPlaying.id
          if self.reloadedFailedTrackId != trackId {
            self.reloadedFailedTrackId = trackId
            if self.isLiveRadio {
              self.reloadRadioItem()
            } else {
              // A song that was under way picks up where it broke, one that
              // never started where it was meant to begin.
              self.isPlaying = true
              self.resumedAtListened = self.secondsListened
              self.loadItem(
                at: self.lastObservedTime > 5
                  ? floor(self.lastObservedTime) : self.pendingStartPosition)
              self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
              return
            }
          } else {
            // The failed item may already be counted, which would leave the
            // skip's guard with nothing to do and the player stuck.
            self.isPlaying = true
            self.nextSong()
            return
          }
        }

        self.player?.play()
        self.announceNowPlaying()
        self.reportPlayback(.playing)
        self.armLoadWatchdog()

        self.isFinished = false
        self.isPlaying = true
        self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
      }
    }
  }

  func pause() {
    playGeneration += 1
    player?.pause()
    reportPlayback(.paused)

    self.isPlaying = false
    self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
  }

  func stop() {
    reportStopped()
    playGeneration += 1
    player?.pause()
    // No observer tick follows while paused, so the reset is applied here.
    // Starting the song over is a new listen, which may count again.
    pendingStartPosition = 0
    progress = 0
    currentTimeString = timeString(for: 0)
    isLocallySaved = false
    secondsListened = 0
    lastObservedTime = 0
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    UserDefaultsManager.nowPlayingQualified = false
    UserDefaultsManager.nowPlayingListened = 0
    // A transcode started mid-song has no start to seek back to.
    if streamOffset > 0 || playerItem == nil {
      detachItem()
    } else {
      player?.seek(to: CMTime.zero)
    }
    // A load still in flight was just invalidated; nothing will finish it.
    isMediaLoading = false

    self.isFinished = true
    self.isPlaying = false
  }

  func seek(to progress: Double) {
    if isLiveRadio { return }

    let target = progress * totalDuration
    self.progress = progress
    currentTimeString = timeString(for: target)

    if playerItem == nil, !isPlaying {
      // A load still under way would attach at its old target, and without an
      // item no observer tick saves the new position.
      detachItem()
      // The dropped load will not finish.
      isMediaLoading = false
      pendingStartPosition = target
      UserDefaultsManager.nowPlayingProgress = progress
      UserDefaultsManager.nowPlayingListened = self.secondsListened
    } else if playerItem == nil
      || (currentSourceIsTranscoded && (target < streamOffset || abs(target - lastObservedTime) > 3))
    {
      // A load under way restarts at the target; a transcode cannot seek far,
      // so the server starts a new one there. The new item has not ticked
      // yet, so a failure before its first tick must resume at the target.
      lastObservedTime = target
      loadItem(at: target)
    } else {
      player?.seek(
        to: CMTime(seconds: target - streamOffset, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }
    self.updateNowPlayingInfo(progress: progress, rate: isPlaying ? 1.0 : 0.0)
    if isPlaying { reportPlayback(.playing, at: target) }
  }

  func setPlaybackMode() {
    if self.playbackMode == PlaybackMode.defaultPlayback {
      self.playbackMode = PlaybackMode.repeatAlbum
    } else if self.playbackMode == PlaybackMode.repeatAlbum {
      self.playbackMode = PlaybackMode.repeatOnce
    } else {
      self.playbackMode = PlaybackMode.defaultPlayback
    }

    UserDefaultsManager.playbackMode = self.playbackMode
  }

  // The play functions return whether playback started. An item without
  // songs (e.g. an album whose tracks are still loading) leaves the current
  // queue untouched, so callers only show Now Playing on success.

  @discardableResult
  func playBySong<T: Playable>(idx: Int, item: T, isFromLocal: Bool) -> Bool {
    guard item.songs.indices.contains(idx) else { return false }
    startGeneration += 1
    reportStopped()
    resetSession()
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: idx, item: queue)
    return true
  }

  @discardableResult
  func playItem<T: Playable>(item: T, isFromLocal: Bool) -> Bool {
    guard !item.songs.isEmpty else { return false }
    startGeneration += 1
    reportStopped()
    resetSession()
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: 0, item: queue)
    return true
  }

  @discardableResult
  func shuffleItem<T: Playable>(item: T, isFromLocal: Bool) -> Bool {
    guard !item.songs.isEmpty else { return false }
    startGeneration += 1
    reportStopped()
    resetSession()
    var shuffledItem = item
    shuffledItem.songs.shuffle()

    let queue = PlaybackService.shared.addToQueue(item: shuffledItem, isFromLocal: isFromLocal)
    self.addToQueue(idx: 0, item: queue)
    return true
  }

  @discardableResult
  func playRadioItem(radio: Radio) -> Bool {
    guard let radioUrl = Self.normalizedRadioURL(from: radio.streamUrl) else {
      return false
    }
    startGeneration += 1
    reportStopped()
    resetSession()

    let item = radio.toPlayable()
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: false)

    self.activeQueueIdx = 0
    self.queue = queue
    self.isLocallySaved = false

    // A queued end notification from the previous track must not advance the
    // radio queue; live streams have no track end.
    detachItem()
    replacePlayerIfFailed()

    self.radioURL = radioUrl
    self.playerItem = AVPlayerItem(url: radioUrl)
    self.player?.replaceCurrentItem(with: self.playerItem)

    self.observeItemStatus(trackId: self.nowPlaying.id)

    self.isMediaLoading = true
    self.isMediaFailed = false
    self.totalDuration = self.nowPlaying.duration
    self.progress = 0.0
    self.currentTimeString = "00:00"
    self.totalTimeString = "00:00"

    self.addPeriodicTimeObserver()
    self.play()

    self.initNowPlayingInfo(
      title: item.name,
      artist: item.artist,
      playbackDuration: 0)
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    return true
  }

  private static func normalizedRadioURL(from streamUrl: String) -> URL? {
    let trimmedUrl = streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUrl.isEmpty else { return nil }

    if let url = URL(string: trimmedUrl), url.scheme != nil {
      return url
    }

    if let encoded = trimmedUrl.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
      let url = URL(string: encoded),
      url.scheme != nil
    {
      return url
    }

    let withScheme = "https://\(trimmedUrl)"

    if let url = URL(string: withScheme), url.host != nil {
      return url
    }

    if let encoded = withScheme.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
      let url = URL(string: encoded),
      url.host != nil
    {
      return url
    }

    return nil
  }

  func shuffleCurrentQueue() {
    guard queue.indices.contains(activeQueueIdx) else { return }
    self.isShuffling.toggle()

    if self.isShuffling {
      // Save original order and current song
      self.unshuffledQueue = self.queue
      let currentSong = self.queue[self.activeQueueIdx]

      // Shuffle remaining tracks, keep current song at position 0
      var remaining = self.queue
      remaining.remove(at: self.activeQueueIdx)
      remaining.shuffle()

      self.queue = [currentSong] + remaining
      self.activeQueueIdx = 0
    } else {
      // Restore original order and find the current song in it; an index
      // from the shuffled order must never survive into the restored queue.
      let currentId = self.queue[self.activeQueueIdx].id
      self.queue = self.unshuffledQueue
      self.unshuffledQueue = []
      self.activeQueueIdx = self.queue.firstIndex(where: { $0.id == currentId }) ?? 0
    }

    persistActiveIndex()
    persistShuffleOrder()
  }

  private static let shuffleOrderKey = "queueShuffleOrder"

  /// Saves the shuffled order as positions in the persisted queue, which
  /// stays in the original order.
  private func persistShuffleOrder() {
    guard isShuffling else {
      UserDefaults.standard.removeObject(forKey: Self.shuffleOrderKey)
      return
    }
    let order = queue.compactMap { item in unshuffledQueue.firstIndex { $0 === item } }
    UserDefaults.standard.set(order, forKey: Self.shuffleOrderKey)
  }

  /// Saves the current song's position in the persisted queue order, which is
  /// the unshuffled one, so a relaunch restores the song that was playing.
  private func persistActiveIndex() {
    guard queue.indices.contains(activeQueueIdx) else { return }

    var index = activeQueueIdx
    if isShuffling, let currentId = nowPlaying.id,
      let unshuffledIndex = unshuffledQueue.firstIndex(where: { $0.id == currentId })
    {
      index = unshuffledIndex
    }
    UserDefaultsManager.queueActiveIdx = index
  }

  func playFromQueue(idx: Int) {
    startGeneration += 1
    reportStopped()
    self.activeQueueIdx = idx
    self.setNowPlaying()
  }

  func prevSong() {
    // Live radio has no tracks; rebuilding it as a song would stop the stream.
    guard !isLiveRadio else { return }
    reportStopped()
    if self.activeQueueIdx != 0 {
      if self.playbackMode != PlaybackMode.repeatOnce {
        self.activeQueueIdx = self.activeQueueIdx - 1
      }
    } else {
      self.activeQueueIdx = 0
    }

    self.setNowPlaying()
    WKInterfaceDevice.current().play(.click)
  }

  func nextSong(userInitiated: Bool = false) {
    guard !isLiveRadio else { return }
    if userInitiated {
      logSkipIfAbandoned()
    }
    reportStopped()

    if self.queue.count == 1 {
      if self.playbackMode == PlaybackMode.defaultPlayback {
        self.autoPlayOrStop()
      } else {
        self.setNowPlaying()
      }
    } else {
      if self.playbackMode == PlaybackMode.repeatOnce {
        self.setNowPlaying()
      } else if self.playbackMode == PlaybackMode.repeatAlbum {
        if self.activeQueueIdx + 1 > self.queue.count - 1 {
          self.activeQueueIdx = 0
          self.setNowPlaying()
        } else {
          self.activeQueueIdx = self.activeQueueIdx + 1
          self.setNowPlaying()
        }
      } else {
        if self.activeQueueIdx + 1 > self.queue.count - 1 {
          self.autoPlayOrStop()
        } else {
          self.activeQueueIdx = self.activeQueueIdx + 1
          self.setNowPlaying()
        }
      }
    }

    WKInterfaceDevice.current().play(.click)
  }

  /// Pressing next on a barely heard song is a negative signal for smart
  /// shuffle. Only early, user-initiated abandonment counts: natural track
  /// ends, radio, repeat modes that restart the same track and accidental
  /// starts under five seconds do not.
  private func logSkipIfAbandoned() {
    guard self.queue.indices.contains(self.activeQueueIdx), !self.isLiveRadio else { return }
    guard !self.isLocallySaved else { return }

    let restartsSameTrack =
      self.playbackMode == PlaybackMode.repeatOnce
      || (self.queue.count == 1 && self.playbackMode != PlaybackMode.defaultPlayback)
    guard !restartsSameTrack else { return }

    guard self.totalDuration.isFinite, self.totalDuration > 0,
      self.secondsListened >= 5, self.progress < 0.3
    else { return }

    PlaybackJournal.shared.recordSkip(
      self.nowPlaying, origin: self.nowPlaying.playbackOrigin,
      listenedSeconds: self.secondsListened,
      early: self.secondsListened <= PlaybackJournal.earlySkipSeconds)
  }

  /// Something the user started, a logout or a long break ends the session.
  private func resetSession() {
    sessionStartedAt = nil
    lastAcceptedSong = nil
    anchorGenres = []
  }

  /// Navidrome's rule: a play counts after half the song or four minutes of
  /// listening, whichever comes first; seeking ahead does not count. Runs
  /// on main: journal writes stay on the view context's queue and the
  /// submission is asynchronous inside the service.
  private func qualifyIfDue() {
    guard !isLocallySaved, queue.indices.contains(activeQueueIdx), totalDuration.isFinite,
      totalDuration > 0, secondsListened >= min(0.5 * totalDuration, 240)
    else { return }
    isLocallySaved = true
    UserDefaultsManager.nowPlayingQualified = true
    debugLog(
      "qualified after \(String(format: "%.1f", secondsListened))s of "
        + "\(String(format: "%.0f", totalDuration))s")
    PlaybackJournal.shared.recordHeard(
      nowPlaying, origin: nowPlaying.playbackOrigin, listenedSeconds: secondsListened)
    FloooViewModel.shared.scrobble(submission: true, nowPlaying: nowPlaying)
    acceptNowPlaying()
  }

  /// A song heard out seeds the next continuation; the first one of the
  /// session also anchors its genres.
  private func acceptNowPlaying() {
    guard let id = nowPlaying.id, !id.isEmpty else { return }
    lastAcceptedSong = (id, nowPlaying.artistName ?? "", nowPlaying.albumId ?? "")
    guard anchorGenres.isEmpty else { return }
    let session = sessionStartedAt
    Task { @MainActor [weak self] in
      let genres =
        await SmartPlaybackService.shared.libraryIndex(allowSync: false).songs[id]?.genres ?? []
      guard let self, self.sessionStartedAt == session, self.anchorGenres.isEmpty else { return }
      self.anchorGenres = Set(genres)
    }
  }

  private func autoPlayOrStop() {
    guard UserDefaultsManager.keepPlaying else {
      self.stop()
      return
    }
    guard self.queue.indices.contains(self.activeQueueIdx) else {
      self.stop()
      return
    }
    guard !isAutoContinuing else { return }
    isAutoContinuing = true

    // Capture the playback context before the queue is replaced. Until a song
    // was heard out, the session continues from the one that just ended.
    let lastPlayedId = self.nowPlaying.id
    let accepted = self.lastAcceptedSong
    let seedId = accepted?.id ?? lastPlayedId ?? ""
    let seed = SmartPlaybackService.Seed(
      artist: accepted?.artist ?? self.nowPlaying.artistName ?? "",
      albumId: accepted?.albumId ?? self.nowPlaying.albumId ?? "")
    let sessionGenres = self.anchorGenres
    let sessionMinutes = self.sessionStartedAt.map { Date().timeIntervalSince($0) / 60 } ?? 0
    let queueIdList = self.queue.compactMap { $0.id }
    let queueIds = Set(queueIdList)
    // Any play, pause or stop while the mix is generated bumps this; the user
    // took over and the mix must not start playing behind their back.
    let generation = self.playGeneration

    Task { [weak self] in
      // A session without an anchor yet keeps to the seed's genres.
      let anchorGenres =
        sessionGenres.isEmpty
        ? Set(
          await SmartPlaybackService.shared.libraryIndex(allowSync: false).songs[seedId]?.genres
            ?? [])
        : sessionGenres
      debugLog(
        "keep playing: seed=\(seedId) accepted=\(accepted != nil) artist=\(seed.artist) "
          + "album=\(seed.albumId) anchorGenres=\(anchorGenres.sorted()) "
          + "sessionMinutes=\(String(format: "%.1f", sessionMinutes)) queueIds=\(queueIds.count)")
      let songs = await SmartPlaybackService.shared.generateMix(
        count: 10,
        mode: .keepPlaying(
          SmartPlaybackService.KeepPlayingContext(
            seed: seed, anchorGenres: anchorGenres, sessionMinutes: sessionMinutes,
            queueIds: queueIds)))

      await MainActor.run {
        guard let self = self else { return }
        self.isAutoContinuing = false

        // Discard the mix if the user started something else while it was
        // being generated — the ordered queue contents are compared too, so a
        // new queue that happens to start on the same song is not overwritten.
        guard self.queue.indices.contains(self.activeQueueIdx),
          self.nowPlaying.id == lastPlayedId,
          self.queue.compactMap({ $0.id }) == queueIdList,
          self.playGeneration == generation, UserDefaultsManager.keepPlaying
        else { return }

        guard !songs.isEmpty else {
          self.stop()
          return
        }
        debugLog("keep playing: \(songs.count) songs follow")

        let autoPlay = SongCollection(id: "auto-play", name: "Auto Play", songs: songs)
        // Through addToQueue, so shuffle state and failure counts reset like
        // for any other new queue.
        self.addToQueue(
          idx: 0, item: PlaybackService.shared.addToQueue(item: autoPlay, isFromLocal: false))
      }
    }
  }

  func toggleStar() {
    guard let songId = self.nowPlaying.id, !songId.isEmpty else { return }

    let shouldStar = !self.isStarred
    self.isStarred = shouldStar
    starGeneration += 1
    let generation = starGeneration

    let action = shouldStar ? AlbumService.shared.starSong : AlbumService.shared.unstarSong
    action(songId) { [weak self] success in
      if !success {
        DispatchQueue.main.async {
          guard let self, self.starGeneration == generation else { return }
          self.isStarred = !shouldStar
        }
      }
    }
  }

  private func nextQueueIdxForPreCache() -> Int? {
    if queue.count <= 1 { return nil }

    if playbackMode == PlaybackMode.repeatOnce {
      return nil
    }

    if playbackMode == PlaybackMode.repeatAlbum {
      return activeQueueIdx + 1 >= queue.count ? 0 : activeQueueIdx + 1
    }

    let nextIdx = activeQueueIdx + 1
    guard nextIdx < queue.count else { return nil }
    return nextIdx
  }

  deinit {
    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      player?.pause()
    }
  }
}

#if DEBUG
  // Simulator verification only. FLO_DEBUG_PLAY_SOMETHING=1 starts a smart mix
  // a few seconds after launch; FLO_DEBUG_BROKEN_FIRST=1 puts an unknown song
  // first; FLO_DEBUG_SEEK=<0...1> then seeks the first track to that
  // position; the queue state is logged along the way. FLO_DEBUG_BITRATE=<kbps>
  // sets the bitrate limit (it stays in the simulator's defaults),
  // FLO_DEBUG_RESUME_AT=<s> breaks the remote stream once it reaches that
  // position, and FLO_DEBUG_DUMP_LOG=<s> logs the request log at that time.
  // FLO_DEBUG_RATE=<playbackID>:<0-5> rates a song at launch;
  // FLO_DEBUG_SKIP_AFTER=<s> presses next once the first song was heard that long.
  extension WatchPlayerViewModel {
    fileprivate func runDebugLaunchActions() {
      let env = ProcessInfo.processInfo.environment
      if let kbps = env["FLO_DEBUG_BITRATE"] {
        UserDefaultsManager.maxBitRate = kbps
        debugLog("max bitrate set to \(kbps)")
      }
      if let rate = env["FLO_DEBUG_RATE"]?.split(separator: ":"), rate.count == 2,
        let rating = Int(rate[1])
      {
        let id = String(rate[0])
        Task { @MainActor in
          RatingStore.shared.set(rating, playbackID: id)
          debugLog("rated \(id) \(rating)")
        }
      }
      if let delay = env["FLO_DEBUG_DUMP_LOG"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          let entries = RequestLog.shared.entries
          debugLog("request log: \(entries.count) entries")
          for entry in entries.reversed() {
            debugLog(
              "  \(String(format: "%.1f", entry.startedAt)) \(entry.text) "
                + "status=\(entry.status.map(String.init) ?? "-") error=\(entry.error ?? "-")")
          }
        }
      }
      guard env["FLO_DEBUG_PLAY_SOMETHING"] == "1" else { return }

      if let resumeAt = env["FLO_DEBUG_RESUME_AT"].flatMap(Double.init) {
        // Posts the failure notification AVPlayer sends for a broken stream,
        // so the real recovery path runs.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
          guard let self, self.lastObservedTime >= resumeAt, self.currentSourceIsRemote,
            let item = self.playerItem
          else { return }
          timer.invalidate()
          debugLog("simulating stream failure at \(self.lastObservedTime)")
          NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime, object: item,
            userInfo: [
              AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "flo-debug", code: -1)
            ])
        }
      }

      if let skipAfter = env["FLO_DEBUG_SKIP_AFTER"].flatMap(Double.init) {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
          guard let self, self.secondsListened >= skipAfter else { return }
          timer.invalidate()
          debugLog("skipping after \(self.secondsListened)s")
          self.nextSong(userInitiated: true)
        }
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        Task { @MainActor in
          var songs = await SmartPlaybackService.shared.generateMix(
            count: 15, mode: .playSomething)
          debugLog("mix generated: \(songs.count) songs")
          if env["FLO_DEBUG_BROKEN_FIRST"] == "1", let first = songs.first {
            // A song id the server does not know, to exercise failed streams.
            let broken = Song(
              id: "broken-\(first.id)", title: "Broken", albumId: first.albumId,
              albumName: first.albumName, artist: first.artist, trackNumber: 1, discNumber: 1,
              bitRate: 0, sampleRate: 0, suffix: first.suffix, duration: first.duration,
              mediaFileId: "broken-\(first.id)")
            songs.insert(broken, at: 0)
          }
          let mix = SongCollection(id: "smart-shuffle", name: "Smart Shuffle", songs: songs)
          self.playItem(item: mix, isFromLocal: false)

          if let seek = env["FLO_DEBUG_SEEK"].flatMap(Double.init) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.seek(to: seek)
            debugLog("seeked to \(seek)")
          }
        }
      }

      Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
        guard let self = self, self.hasNowPlaying() else { return }
        debugLog(
          "queue=\(self.queue.count) idx=\(self.activeQueueIdx) playing=\(self.isPlaying) "
            + "song=\(self.nowPlaying.id ?? "") progress=\(String(format: "%.2f", self.progress)) "
            + "session=\(self.sessionStartedAt.map { "\(Int(-$0.timeIntervalSinceNow))s" } ?? "none")")
      }
    }
  }
#endif
