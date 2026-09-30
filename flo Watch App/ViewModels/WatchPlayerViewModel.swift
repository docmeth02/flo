//
//  WatchPlayerViewModel.swift
//  flo Watch App
//

import AVFoundation
import Combine
import MediaPlayer
import WatchKit

class WatchPlayerViewModel: ObservableObject {
  private(set) var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var timeObserverToken: Any?

  @Published var queue: [QueueEntity] = []
  @Published var playbackMode = PlaybackMode.defaultPlayback

  @Published var activeQueueIdx: Int = 0

  @Published var isMediaFailed: Bool = false
  @Published var isMediaLoading: Bool = false
  @Published var isShuffling: Bool = false
  @Published var isPlaying: Bool = false

  @Published var progress: Double = 0.0

  @Published var currentTimeString: String = "00:00"
  @Published var totalTimeString: String = "00:00"

  @Published var isStarred: Bool = false

  private var isLocallySaved: Bool = false
  private var isFinished: Bool = false
  private var isAutoContinuing: Bool = false
  private var totalDuration: Double = 0.0
  private var playerItemObservation: AnyCancellable?
  private var playbackEndObservation: AnyCancellable?
  private var interruptionObservation = Set<AnyCancellable>()
  private var logoutObservation: AnyCancellable?
  private var unshuffledQueue: [QueueEntity] = []

  private var scrobbleThreshold = 0.5
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

  var nowPlaying: QueueEntity {
    return self.queue[self.activeQueueIdx]
  }

  var isLiveRadio: Bool {
    guard hasNowPlaying() else { return false }
    return nowPlaying.duration.isInfinite || nowPlaying.duration.isNaN
  }

  init() {
    self.player = AVPlayer()
    self.observeInterruptionNotifications()

    logoutObservation = NotificationCenter.default.publisher(for: .didLogout)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.clearForLogout() }

    let lastPlayData = PlaybackService.shared.getQueue()
    let queueActiveIdx = UserDefaultsManager.queueActiveIdx

    if !lastPlayData.isEmpty && queueActiveIdx < lastPlayData.count {
      self.progress = UserDefaultsManager.nowPlayingProgress
      self.playbackMode = UserDefaultsManager.playbackMode
      self.addToQueue(
        idx: UserDefaultsManager.queueActiveIdx, item: lastPlayData, playAudio: false)

      if self.progress > scrobbleThreshold {
        self.isLocallySaved = true
      }
    } else {
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      PlaybackService.shared.clearQueue()
    }

    self.setupRemoteCommandCenter()

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
      self.isPlaying = false
      self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
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

  /// A failed stream (deleted file, transcoder error, corrupt cache) never
  /// reaches its end, so nothing would advance and playback would sit silent.
  /// Skip ahead after a moment, but stop after a few failures in a row so an
  /// unreachable server does not burn through the whole queue.
  private func skipFailedTrack(trackId: String?) {
    loadWatchdog?.cancel()
    guard queue.indices.contains(activeQueueIdx), nowPlaying.id == trackId, !isLiveRadio else {
      return
    }
    consecutiveFailures += 1
    debugLog("stream failed: \(trackId ?? "") (\(consecutiveFailures) in a row)")
    guard consecutiveFailures <= Self.maxConsecutiveFailures else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self = self, self.queue.indices.contains(self.activeQueueIdx),
        self.nowPlaying.id == trackId
      else { return }
      self.nextSong()
    }
  }

  /// Stops playback and forgets the queue; its songs belong to the account
  /// that just logged out.
  private func clearForLogout() {
    playGeneration += 1
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }
    playerItemObservation?.cancel()
    playbackEndObservation?.cancel()
    playbackEndObservation = nil
    playbackFailureObservation = nil
    loadWatchdog?.cancel()
    playerItem = nil

    queue = []
    activeQueueIdx = 0
    unshuffledQueue = []
    isShuffling = false
    isPlaying = false
    progress = 0

    PlaybackService.shared.clearQueue()
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  func addToQueue(idx: Int, item: [QueueEntity], playAudio: Bool = true) {
    // A new queue starts unshuffled; the saved order belongs to the old one.
    self.isShuffling = false
    self.unshuffledQueue = []
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
      if let timeObserverToken = timeObserverToken {
        player?.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
      }
      playerItemObservation?.cancel()
      playbackEndObservation?.cancel()
      playbackEndObservation = nil
      isMediaLoading = false
      isMediaFailed = true
      return
    }

    self.persistActiveIndex()
    self.isLocallySaved = false
    self.hasTriggeredCache = false
    self.secondsListened = 0
    self.lastObservedTime = 0

    StreamCacheManager.shared.cancelAllInFlight()
    StreamCacheManager.shared.setCurrentlyPlaying(mediaFileId: self.nowPlaying.id ?? "")

    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
    }

    let streamUrl = AlbumService.shared.getStreamUrl(id: self.nowPlaying.id ?? "")

    guard let audioURL = URL(string: streamUrl), !streamUrl.isEmpty else {
      player?.pause()
      player?.replaceCurrentItem(with: nil)
      isMediaLoading = false
      isMediaFailed = true
      return
    }

    self.playerItem = AVPlayerItem(url: audioURL)
    self.player?.replaceCurrentItem(with: self.playerItem)

    // Songs from Subsonic endpoints can carry sampleRate 0, which would make
    // an invalid CMTime and a NaN duration — the end-of-track check would
    // never fire and playback would stall after every song.
    let timescale =
      self.nowPlaying.sampleRate > 0 ? self.nowPlaying.sampleRate : CMTimeScale(NSEC_PER_SEC)
    let duration = CMTime(seconds: self.nowPlaying.duration, preferredTimescale: timescale)
    let playbackDuration = CMTimeGetSeconds(duration)

    self.totalDuration = playbackDuration
    self.totalTimeString = timeString(for: playbackDuration)

    let newTimeString = self.progress * playbackDuration
    self.currentTimeString = timeString(for: newTimeString)

    let trackId = self.nowPlaying.id
    self.playerItemObservation = self.playerItem?.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        guard let self = self else { return }
        switch status {
        case .readyToPlay:
          self.consecutiveFailures = 0
          self.loadWatchdog?.cancel()
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard self.queue.indices.contains(self.activeQueueIdx),
                  self.nowPlaying.id == trackId else { return }
            self.isMediaLoading = false
            self.isMediaFailed = false
          }
        case .failed:
          self.isMediaLoading = false
          self.isMediaFailed = true
          self.skipFailedTrack(trackId: trackId)
        case .unknown:
          self.isMediaLoading = false
        @unknown default:
          self.isMediaLoading = true
        }
      }

    // A server that never answers leaves the item loading forever without
    // reporting .failed, and a stream can also break mid-song; both count as
    // failures so playback moves on instead of sitting silent.
    self.loadWatchdog?.cancel()
    if playAudio {
      let watchdog = DispatchWorkItem { [weak self] in
        // A user who paused while the track was loading must not be pulled
        // into the next song.
        guard let self = self, self.isPlaying, self.playerItem?.status != .readyToPlay else {
          return
        }
        self.player?.pause()
        self.skipFailedTrack(trackId: trackId)
      }
      self.loadWatchdog = watchdog
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: watchdog)
    }
    self.playbackFailureObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: self.playerItem)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.skipFailedTrack(trackId: trackId) }

    // Fallback advance for items whose reported duration is off (VBR, missing
    // metadata): if the periodic check misses the end, the player item itself
    // tells us. The observation is per-item, so a track advanced by the
    // periodic check never double-fires here.
    self.playbackEndObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemDidPlayToEndTime, object: self.playerItem)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.nextSong()
        UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      }

    if playAudio {
      self.seek(to: 0.0)
      self.play()
    } else {
      self.seek(to: self.progress)
    }

    self.addPeriodicTimeObserver()
    self.initNowPlayingInfo(
      title: self.nowPlaying.songName ?? "",
      artist: self.nowPlaying.artistName ?? "",
      playbackDuration: self.totalDuration)

    self.isStarred = false
    // A queue restored at launch stays paused; telling the server it is
    // playing, or asking about it, waits until the user actually plays it.
    self.needsNowPlayingAnnouncement = true
    if playAudio {
      self.announceNowPlaying()
    }
  }

  /// Reports the current song as playing to the server and loads its starred
  /// state, once per song.
  private func announceNowPlaying() {
    guard needsNowPlayingAnnouncement, queue.indices.contains(activeQueueIdx) else { return }
    needsNowPlayingAnnouncement = false

    FloooViewModel.shared.setNowPlayingToScrobbleServer(nowPlaying: self.nowPlaying)

    if let songId = self.nowPlaying.id, !songId.isEmpty {
      AlbumService.shared.isStarred(songId: songId) { [weak self] starred in
        DispatchQueue.main.async {
          guard self?.queue.indices.contains(self?.activeQueueIdx ?? -1) == true,
                self?.nowPlaying.id == songId else { return }
          self?.isStarred = starred
        }
      }
    }
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
        self.playerItem === observedItem
      else { return }
      let currentTime = CMTimeGetSeconds(time)
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
      if (self.player?.rate ?? 0) > 0, step > 0, step <= 1.5 {
        self.secondsListened += step
      }
      self.lastObservedTime = currentTime

      UserDefaultsManager.nowPlayingProgress = self.progress

      if !self.hasTriggeredCache && currentTime >= 10.0 && !self.isLiveRadio {
        self.hasTriggeredCache = true
        if let nextIdx = self.nextQueueIdxForPreCache(),
          let nextId = self.queue[nextIdx].id, !nextId.isEmpty
        {
          StreamCacheManager.shared.cacheSong(
            mediaFileId: nextId, originalSuffix: self.queue[nextIdx].suffix,
            from: self.queue[nextIdx])
        }
      }

      // Runs on main (observer queue) — history writes stay on viewContext's
      // queue and the network submission is async inside the service anyway.
      if !self.isLocallySaved && self.progress >= 0.5 {
        self.isLocallySaved = true
        FloooViewModel.shared.scrobble(submission: true, nowPlaying: self.nowPlaying)
      }

      if self.totalDuration.isFinite,
        self.totalDuration > 0,
        round(currentTime) >= roundedTotalDuration
      {
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

        self.player?.play()
        self.announceNowPlaying()

        self.isFinished = false
        self.isPlaying = true
        self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
      }
    }
  }

  func pause() {
    playGeneration += 1
    player?.pause()

    self.isPlaying = false
    self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
  }

  func stop() {
    playGeneration += 1
    player?.pause()
    player?.seek(to: CMTime.zero)

    self.isFinished = true
    self.isPlaying = false
  }

  func seek(to progress: Double) {
    if isLiveRadio { return }

    let newTime = CMTime(
      seconds: progress * totalDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    player?.seek(to: newTime)
    self.updateNowPlayingInfo(progress: progress, rate: 1.0)
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
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: idx, item: queue)
    return true
  }

  @discardableResult
  func playItem<T: Playable>(item: T, isFromLocal: Bool) -> Bool {
    guard !item.songs.isEmpty else { return false }
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: 0, item: queue)
    return true
  }

  @discardableResult
  func shuffleItem<T: Playable>(item: T, isFromLocal: Bool) -> Bool {
    guard !item.songs.isEmpty else { return false }
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

    let item = radio.toPlayable()
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: false)

    self.activeQueueIdx = 0
    self.queue = queue
    self.isLocallySaved = false

    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }

    // A queued end notification from the previous track must not advance the
    // radio queue — live streams have no track end.
    self.playbackEndObservation?.cancel()
    self.playbackEndObservation = nil
    self.playbackFailureObservation = nil
    self.loadWatchdog?.cancel()

    self.playerItem = AVPlayerItem(url: radioUrl)
    self.player?.replaceCurrentItem(with: self.playerItem)

    let radioTrackId = self.nowPlaying.id
    self.playerItemObservation = self.playerItem?.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        guard let self = self else { return }
        switch status {
        case .readyToPlay:
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard self.queue.indices.contains(self.activeQueueIdx),
                  self.nowPlaying.id == radioTrackId else { return }
            self.isMediaLoading = false
            self.isMediaFailed = false
          }
        case .failed:
          self.isMediaLoading = false
          self.isMediaFailed = true
        case .unknown:
          self.isMediaLoading = false
        @unknown default:
          self.isMediaLoading = true
        }
      }

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
    PlaybackService.shared.clearQueue()
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
    self.activeQueueIdx = idx
    self.setNowPlaying()
  }

  func prevSong() {
    // Live radio has no tracks; rebuilding it as a song would stop the stream.
    guard !isLiveRadio else { return }
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

    FloooViewModel.shared.logSkip(nowPlaying: self.nowPlaying)
  }

  private func autoPlayOrStop() {
    // Remote command handlers may call in off the main thread; the flag and
    // all playback state are only touched on main.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.autoPlayOrStop() }
      return
    }
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

    // Capture the playback context before the queue is replaced.
    let lastPlayedId = self.nowPlaying.id
    let seed = SmartPlaybackService.Seed(
      artist: self.nowPlaying.artistName ?? "",
      albumId: self.nowPlaying.albumId ?? "")
    let queueIdList = self.queue.compactMap { $0.id }
    let queueIds = Set(queueIdList)
    // Any play, pause or stop while the mix is generated bumps this; the user
    // took over and the mix must not start playing behind their back.
    let generation = self.playGeneration

    Task { [weak self] in
      let songs = await SmartPlaybackService.shared.generateMix(
        count: 10, seed: seed, queueIds: queueIds)

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

        let autoPlay = SongCollection(id: "auto-play", name: "Auto Play", songs: songs)
        self.queue = PlaybackService.shared.addToQueue(item: autoPlay, isFromLocal: false)
        self.activeQueueIdx = 0
        self.setNowPlaying()
      }
    }
  }

  func toggleStar() {
    guard let songId = self.nowPlaying.id, !songId.isEmpty else { return }

    let shouldStar = !self.isStarred
    self.isStarred = shouldStar

    let action = shouldStar ? AlbumService.shared.starSong : AlbumService.shared.unstarSong
    action(songId) { [weak self] success in
      if !success {
        DispatchQueue.main.async {
          guard self?.nowPlaying.id == songId else { return }
          self?.isStarred = !shouldStar
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
  // position; the queue state is logged along the way.
  extension WatchPlayerViewModel {
    fileprivate func runDebugLaunchActions() {
      let env = ProcessInfo.processInfo.environment
      guard env["FLO_DEBUG_PLAY_SOMETHING"] == "1" else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        Task { @MainActor in
          var songs = await SmartPlaybackService.shared.generateMix(count: 15)
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
            + "song=\(self.nowPlaying.id ?? "") progress=\(String(format: "%.2f", self.progress))")
      }
    }
  }
#endif
