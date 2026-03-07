//
//  WatchPlayerViewModel.swift
//  flo Watch App
//

import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import WatchKit

class WatchPlayerViewModel: ObservableObject {
  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var timeObserverToken: Any?

  @Published var queue: [QueueEntity] = []
  @Published var playbackMode = PlaybackMode.defaultPlayback

  @Published var activeQueueIdx: Int = 0

  @Published var isMediaFailed: Bool = false
  @Published var isMediaLoading: Bool = false
  @Published var isShuffling: Bool = false
  @Published var isPlaying: Bool = false
  @Published var isSeeking: Bool = false

  @Published var progress: Double = 0.0

  @Published var currentTimeString: String = "00:00"
  @Published var totalTimeString: String = "00:00"

  @Published var _playFromLocal: Bool = false
  @Published var isStarred: Bool = false

  private var isLocallySaved: Bool = false
  private var isFinished: Bool = false
  private var totalDuration: Double = 0.0
  private var playerItemObservation: AnyCancellable?
  private var interruptionObservation = Set<AnyCancellable>()
  private var unshuffledQueue: [QueueEntity] = []

  private var scrobbleThreshold = 0.5
  private var hasTriggeredCache: Bool = false

  var nowPlaying: QueueEntity {
    return self.queue[self.activeQueueIdx]
  }

  var isLiveRadio: Bool {
    guard hasNowPlaying() else { return false }
    return nowPlaying.duration.isInfinite || nowPlaying.duration.isNaN
  }

  var isPlayFromSource: Bool {
    return self._playFromLocal
      || UserDefaultsManager.maxBitRate == TranscodingSettings.sourceBitRate
  }

  init() {
    self.player = AVPlayer()
    self.observeInterruptionNotifications()

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
  }

  func observeInterruptionNotifications() {
    NotificationCenter.default
      .publisher(for: AVAudioSession.interruptionNotification)
      .sink { notification in
        self.handleInterruptionNotification(notification)
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
      DispatchQueue.main.async {
        self.isPlaying = false
        self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
      }
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

  func addToQueue(idx: Int, item: [QueueEntity], playAudio: Bool = true) {
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
    self.isLocallySaved = false
    self.hasTriggeredCache = false

    StreamCacheManager.shared.cancelAllInFlight()
    StreamCacheManager.shared.setCurrentlyPlaying(mediaFileId: self.nowPlaying.id ?? "")

    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
    }

    let audioURL = URL(
      string: AlbumService.shared.getStreamUrl(id: self.nowPlaying.id ?? ""))

    self._playFromLocal = audioURL?.isFileURL == true

    self.playerItem = AVPlayerItem(url: audioURL!)
    self.player?.replaceCurrentItem(with: self.playerItem)

    let duration = CMTime(
      seconds: self.nowPlaying.duration, preferredTimescale: self.nowPlaying.sampleRate)
    let playbackDuration = CMTimeGetSeconds(duration)

    self.totalDuration = playbackDuration
    self.totalTimeString = timeString(for: playbackDuration)

    let newTimeString = self.progress * playbackDuration
    self.currentTimeString = timeString(for: newTimeString)

    self.playerItemObservation = self.playerItem?.publisher(for: \.status)
      .sink { [weak self] status in
        guard let self = self else { return }
        switch status {
        case .readyToPlay:
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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

    FloooViewModel.shared.setNowPlayingToScrobbleServer(nowPlaying: self.nowPlaying)

    self.isStarred = false
    if let songId = self.nowPlaying.id, !songId.isEmpty {
      AlbumService.shared.isStarred(songId: songId) { [weak self] starred in
        DispatchQueue.main.async {
          guard self?.nowPlaying.id == songId else { return }
          self?.isStarred = starred
        }
      }
    }
  }

  private func addPeriodicTimeObserver() {
    guard let player = self.player else { return }

    let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      let currentTime = CMTimeGetSeconds(time)
      let roundedTotalDuration = floor(self.totalDuration)

      self.progress = currentTime / self.totalDuration
      self.currentTimeString = timeString(for: currentTime)

      UserDefaultsManager.nowPlayingProgress = self.progress

      if !self.hasTriggeredCache && currentTime >= 10.0 && !self.isLiveRadio {
        self.hasTriggeredCache = true
        if let nextIdx = self.nextQueueIdxForPreCache(),
          let nextId = self.queue[nextIdx].id, !nextId.isEmpty
        {
          StreamCacheManager.shared.cacheSong(
            mediaFileId: nextId, originalSuffix: self.queue[nextIdx].suffix)
        }
      }

      if !self.isLocallySaved && self.progress >= 0.5 {
        Task {
          FloooViewModel.shared.scrobble(submission: true, nowPlaying: self.nowPlaying)
          self.isLocallySaved = true
        }
      }

      if round(currentTime) >= roundedTotalDuration {
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

    if albumCoverArt.hasPrefix("/") {
      // Local file - load directly
      if let image = UIImage(contentsOfFile: albumCoverArt) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    } else if let imageURL = URL(string: albumCoverArt) {
      // Remote URL - use URLSession for reliable download on watchOS
      URLSession.shared.dataTask(with: imageURL) { data, _, error in
        guard let data = data, let image = UIImage(data: data) else {
          if let error = error {
            print("Now Playing artwork download failed: \(error)")
          }
          return
        }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

        DispatchQueue.main.async {
          var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
          info[MPMediaItemPropertyArtwork] = artwork
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
      }.resume()
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

    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [unowned self] event in
      self.play()
      return .success
    }

    commandCenter.pauseCommand.addTarget { [unowned self] event in
      self.pause()
      return .success
    }

    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.nextTrackCommand.addTarget { event in
      self.nextSong()
      return .success
    }

    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.addTarget { event in
      self.prevSong()
      return .success
    }

    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.addTarget { event in
      if self.isLiveRadio {
        return .commandFailed
      }
      if let event = event as? MPChangePlaybackPositionCommandEvent {
        let progress = event.positionTime / self.totalDuration
        self.seek(to: progress)
        return .success
      }
      return .commandFailed
    }
  }

  func play() {
    // Activate audio session using watchOS async API
    AVAudioSession.sharedInstance().activate(options: []) { [weak self] success, error in
      guard let self = self else { return }
      if let error = error {
        print("Audio session activation failed: \(error)")
        return
      }

      DispatchQueue.main.async {
        if self.isFinished {
          self.stop()
          self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
        }

        self.player?.play()

        self.isFinished = false
        self.isPlaying = true
        self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
      }
    }
  }

  func pause() {
    player?.pause()

    self.isPlaying = false
    self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
  }

  func stop() {
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

  func playBySong<T: Playable>(idx: Int, item: T, isFromLocal: Bool) {
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: idx, item: queue)
  }

  func playItem<T: Playable>(item: T, isFromLocal: Bool) {
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: isFromLocal)
    self.addToQueue(idx: 0, item: queue)
  }

  func shuffleItem<T: Playable>(item: T, isFromLocal: Bool) {
    var shuffledItem = item
    shuffledItem.songs.shuffle()

    let queue = PlaybackService.shared.addToQueue(item: shuffledItem, isFromLocal: isFromLocal)
    self.addToQueue(idx: 0, item: queue)
  }

  func playRadioItem(radio: Radio) {
    guard let radioUrl = Self.normalizedRadioURL(from: radio.streamUrl) else {
      return
    }

    let item = radio.toPlayable()
    let queue = PlaybackService.shared.addToQueue(item: item, isFromLocal: false)

    self.activeQueueIdx = 0
    self.queue = queue
    self.isLocallySaved = false
    self._playFromLocal = false

    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }

    self.playerItem = AVPlayerItem(url: radioUrl)
    self.player?.replaceCurrentItem(with: self.playerItem)

    self.playerItemObservation = self.playerItem?.publisher(for: \.status)
      .sink { [weak self] status in
        guard let self = self else { return }
        switch status {
        case .readyToPlay:
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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
      // Restore original order, find current song in it
      let currentId = self.queue[self.activeQueueIdx].id
      self.queue = self.unshuffledQueue

      if let idx = self.queue.firstIndex(where: { $0.id == currentId }) {
        self.activeQueueIdx = idx
      }
    }
  }

  func playFromQueue(idx: Int) {
    self.activeQueueIdx = idx
    self.setNowPlaying()

    UserDefaultsManager.queueActiveIdx = self.activeQueueIdx
  }

  func prevSong() {
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

  func nextSong() {
    if self.queue.count == 1 {
      if self.playbackMode == PlaybackMode.defaultPlayback {
        self.stop()
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
          self.stop()
        } else {
          self.activeQueueIdx = self.activeQueueIdx + 1
          self.setNowPlaying()
        }
      }
    }

    UserDefaultsManager.queueActiveIdx = self.activeQueueIdx
    WKInterfaceDevice.current().play(.click)
  }

  func destroyPlayerAndQueue() {
    self.stop()
    self.progress = 0.0

    self.isLocallySaved = false

    PlaybackService.shared.clearQueue()
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

    self.queue = []
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
