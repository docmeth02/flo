//
//  PlayerViewModel.swift
//  flo
//

import AVFoundation
import Combine
import MediaPlayer

/// The values that change every second while playing, apart from the view
/// model so that only the views showing them redraw that often.
final class PlayerClock: ObservableObject {
  @Published var progress: Double = 0.0
  @Published var currentTimeString: String = "00:00"

  var clampedProgress: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }
}

class PlayerViewModel: ObservableObject {
  var player: AVPlayer? {
    didSet { observeBuffering() }
  }
  var playerItem: AVPlayerItem?
  var timeObserverToken: Any?

  @Published var queue: [QueueEntity] = []
  @Published var playbackMode = PlaybackMode.defaultPlayback

  @Published var activeQueueIdx: Int = 0

  @Published var isMediaFailed: Bool = false
  @Published var isMediaLoading: Bool = false
  /// AVPlayer is waiting for data before it can play, as at the start of a
  /// song after a skip; isMediaLoading only covers the time until the item
  /// exists.
  @Published var isBuffering = false
  /// The server is out of reach: the song keeps its position and stays
  /// wanted (isPlaying) until it can load again.
  @Published private(set) var isWaitingForConnection = false
  /// The song is not on the device and streaming is switched off on this
  /// network (the phone on cellular); it waits paused.
  @Published var isStreamingBlocked = false
  @Published var isShuffling: Bool = false
  @Published var isPlaying: Bool = false

  let clock = PlayerClock()
  var progress: Double {
    get { clock.progress }
    set { clock.progress = newValue }
  }
  var currentTimeString: String {
    get { clock.currentTimeString }
    set { clock.currentTimeString = newValue }
  }
  /// The now playing cover, resolved once per song rather than on every redraw.
  @Published var coverArt: String = ""

  /// The heart: StarStore's edits over the server's star for the song.
  @Published var isStarred: Bool = false
  // The server's star for the current song, looked up once per song.
  var serverStarred = false
  // That lookup failed; announcing the song asks again.
  var starLookupFailed = false
  // Bumped by every lookup; an older answer, even for the same song, is stale.
  var starLookup = 0
  private var starObservation: AnyCancellable?
  var resumeAfterInterruption = false
  // A start the system may still interrupt while it sets up the output. On
  // watchOS 26 the activation succeeds without an output; the speaker or the
  // headphones are only brought up once the player renders, and bringing them
  // up interrupts the session (reason default) without ever ending the
  // interruption. Those interruptions keep the start, which resumes once the
  // route has settled, at most `maxSettleResumes` times. Over once the player
  // has played `startHeardAfter` seconds into an output, or by a pause.
  // The setup can also interrupt before the activation has answered, while
  // isPlaying is not set yet; that start is kept too.
  struct PendingStart {
    var resumes = 0
    var played: Double = 0
    // From play() until its activation answers, or a stop drops it.
    var isActivating = true
    var interruptedWhileActivating = false
  }
  var pendingStart: PendingStart?
  var settleWork: DispatchWorkItem?
  static let settleDelay: TimeInterval = 1.5
  static let maxSettleResumes = 3
  static let startHeardAfter: Double = 3
  var accessLogObservation: AnyCancellable?
  var loadedRangesObservation: AnyCancellable?
  // When the current transcode last received data.
  var bufferGrewAt: Date?

  var hasQualified: Bool = false
  private(set) var isFinished: Bool = false
  var isAutoContinuing: Bool = false
  var totalDuration: Double = 0.0
  var playerItemObservation: AnyCancellable?
  var bufferingObservation: AnyCancellable?
  var playbackEndObservation: AnyCancellable?
  var interruptionObservation = Set<AnyCancellable>()
  private var logoutObservation: AnyCancellable?
  private var reachabilityObservation: AnyCancellable?
  // The stored order while shuffling (`queue` is the play order), else empty.
  var unshuffledQueue: [QueueEntity] = []

  private var hasTriggeredCache: Bool = false
  // Audible playback of the current item; unlike the playhead position,
  // seeking cannot inflate or erase it.
  private(set) var secondsListened: Double = 0
  private(set) var lastObservedTime: Double = 0
  private(set) var playGeneration: Int = 0
  var consecutiveFailures: Int = 0
  static let maxConsecutiveFailures = 3
  // Long enough for a slow cellular start, short enough not to feel stuck.
  static let loadTimeout: TimeInterval = 20
  var loadWatchdog: DispatchWorkItem?
  // A remote song waiting for data mid-song gets this long before it is
  // reloaded where it stopped; a hanging connection never fails the item.
  static let stallTimeout: TimeInterval = 15
  var stallDeadline: DispatchWorkItem?
  // Bumped whenever a no-progress check in flight no longer applies.
  var noProgressCheck = 0
  // The current item has played; before that the load watchdog guards it.
  var itemHasPlayed = false
  // Behind isWaitingForConnection: when the wait began, its probe timer and
  // whether a load is under way.
  struct ConnectionWait {
    let since: Date
    let timer: Timer
    var isReloading = false
  }
  var connectionWait: ConnectionWait? {
    didSet {
      let waiting = connectionWait != nil
      if waiting != isWaitingForConnection { isWaitingForConnection = waiting }
    }
  }
  static let connectionProbeInterval: TimeInterval = 30
  static let connectionWaitLimit: TimeInterval = 5 * 60
  var playbackFailureObservation: AnyCancellable?
  private var needsNowPlayingAnnouncement = false
  // The song whose failed item Play already reloaded once; a second failure
  // goes through the capped skip instead of reloading again. Cleared once the
  // song plays.
  var reloadedFailedTrackId: String?
  var radioURL: URL?
  // The item whose failure was already counted; KVO, the failure notification
  // and Play can all report the same one.
  weak var countedFailedItem: AVPlayerItem?
  // Track seconds at the current item's time 0; above 0 only for a transcode
  // the server started mid-track.
  var streamOffset: Double = 0
  // Where Play starts the song while no item is attached (restored queue,
  // stop, a load still waiting for its stream source).
  var pendingStartPosition: Double = 0
  var currentSourceIsRemote = false
  var currentSourceIsTranscoded = false
  // Listening time at the last mid-song resume; a stream that breaks again
  // before 30 s more were heard is skipped rather than resumed over and over.
  // Listening time, not position: a seek back must not block the next resume.
  var resumedAtListened: Double?
  // The song whose stream was asked for a second time after failing before it
  // got going; unlike reloadedFailedTrackId it survives the new item playing,
  // so a stream that keeps dying right after its start is not reloaded
  // forever.
  var restartedTrackId: String?
  // Bumped whenever the item is detached; a stream source resolved for an
  // older load is dropped. playGeneration moves with play/pause and cannot
  // tell.
  var loadGeneration = 0
  // The listening session Keep Playing continues: when it began, the last
  // song heard out (never a skip) and the genres the first such song set.
  var sessionStartedAt: Date?
  private var lastPlaybackAt: Date?
  var lastAcceptedSong: (id: String, artist: String, albumId: String)?
  var anchorGenres: Set<String> = []
  private static let sessionTimeout: TimeInterval = 30 * 60
  private var ratingObservation: AnyCancellable?
  /// Bumped whenever the user starts something new; a mix built in the
  /// meantime is stale.
  private var startGeneration = 0
  @Published private(set) var isGeneratingMix = false

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

    // Every successful probe republishes true; a heart lookup skipped offline
    // is made, a song waiting for the server reloads, and a pre-cache that
    // failed while it was gone gets another go.
    reachabilityObservation = ConnectivityMonitor.shared.$isServerReachable
      .filter { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated { self.loadStarred(refresh: true) }
        guard self.isPlaying else { return }
        self.reloadAfterConnectionWait()
        self.precacheUpcoming()
      }

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
      // the stored queue keeps the original order.
      let order = (UserDefaults.standard.array(forKey: Self.shuffleOrderKey) as? [Int])
        .flatMap { $0.sorted() == Array(lastPlayData.indices) ? $0 : nil }
      self.replaceQueue(
        order?.map { lastPlayData[$0] } ?? lastPlayData,
        at: order?.firstIndex(of: queueActiveIdx) ?? queueActiveIdx,
        unshuffled: order == nil ? [] : lastPlayData)
      self.setNowPlaying(playAudio: false)
      // A song that already counted must not count again after a relaunch,
      // and one that did not yet keeps the listening time it had.
      self.hasQualified = UserDefaultsManager.nowPlayingQualified
      self.secondsListened = UserDefaultsManager.nowPlayingListened
      debugLog(
        "restored \(self.nowPlaying.id ?? "") qualified=\(self.hasQualified) "
          + "listened=\(Int(self.secondsListened))s")
    } else {
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
      UserDefaults.standard.removeObject(forKey: Self.shuffleOrderKey)
      PlaybackService.shared.clearQueue()
    }

    self.setupRemoteCommandCenter()
    // Like and dislike follow the rating and the heart the star, wherever
    // they were changed.
    Task { @MainActor [weak self] in
      self?.ratingObservation = RatingStore.shared.$ratings
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateRatingCommands() }
      self?.starObservation = StarStore.shared.$stars
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateHeart() }
    }

    #if DEBUG
      runDebugLaunchActions()
    #endif
  }

  /// Stops playback and forgets the queue; its songs belong to the account
  /// that just logged out.
  private func clearForLogout() {
    // No report: the credentials are gone before this runs.
    resetSession()
    playGeneration += 1
    startGeneration += 1
    endStart()
    endConnectionWait(because: "logout")
    player?.pause()
    detachItem()

    queue = []
    activeQueueIdx = 0
    unshuffledQueue = []
    isShuffling = false
    persistShuffleOrder()
    isPlaying = false
    progress = 0
    coverArt = ""
    reloadedFailedTrackId = nil

    PlaybackService.shared.clearQueue()
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.queueActiveIdx)
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MainActor.assumeIsolated {
      updateRatingCommands()
      NowPlayingTarget.current = nil
    }
  }

  func addToQueue(idx: Int, item: [QueueEntity]) {
    replaceQueue(item, at: idx)
    setNowPlaying()
  }

  /// Takes `items` as the queue in play order. A new queue starts unshuffled,
  /// since a saved order belongs to the old one; only a restored one passes
  /// its stored order as `unshuffled`.
  func replaceQueue(_ items: [QueueEntity], at idx: Int, unshuffled: [QueueEntity] = []) {
    isShuffling = !unshuffled.isEmpty
    unshuffledQueue = unshuffled
    consecutiveFailures = 0
    activeQueueIdx = idx
    queue = items
    persistShuffleOrder()
  }

  func hasNowPlaying() -> Bool {
    queue.indices.contains(activeQueueIdx)
  }

  var nowPlayingId: String? { hasNowPlaying() ? nowPlaying.id : nil }

  func isCurrentTrack(_ id: String?) -> Bool {
    hasNowPlaying() && nowPlaying.id == id
  }

  /// Whether the song is the one in the player, by the id the queue uses.
  func isCurrent(_ song: Song) -> Bool {
    isCurrentTrack(song.playbackID)
  }

  private func setNowPlaying(playAudio: Bool = true) {
    endConnectionWait(because: "song change")
    guard hasNowPlaying() else { return }

    self.persistActiveIndex()
    self.hasQualified = false
    self.hasTriggeredCache = false
    self.secondsListened = 0
    self.lastObservedTime = 0
    self.resumedAtListened = nil
    self.restartedTrackId = nil
    self.reloadedFailedTrackId = nil

    // Before its 10 s this only cancels downloads no longer upcoming; the
    // song after next may already be on its way.
    precacheUpcoming()
    StreamCacheManager.shared.setCurrentlyPlaying(mediaFileId: self.nowPlaying.id ?? "")

    // The item itself is attached by play(), so a queue restored at launch
    // streams nothing until the user presses Play.
    self.detachItem()
    self.isMediaLoading = false

    self.totalDuration = self.nowPlaying.duration

    if playAudio {
      self.progress = 0
      // The first observer tick now waits for the stream decision; a kill in
      // between must not restore this song at the previous one's position.
      UserDefaultsManager.nowPlayingProgress = 0
      UserDefaultsManager.nowPlayingQualified = false
      UserDefaultsManager.nowPlayingListened = 0
    }
    self.pendingStartPosition = self.progress * self.totalDuration
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

    self.publishNowPlaying(
      title: self.nowPlaying.songName ?? "",
      artist: self.nowPlaying.artistName ?? "",
      duration: self.totalDuration)
    // Nothing is attached yet, so the restored position is published here.
    if !playAudio {
      self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
    }

    // Also for a restored queue, so the first tap on the heart is the right way.
    MainActor.assumeIsolated { loadStarred() }
  }

  /// Reports the current song as playing to the server, once per song.
  private func announceNowPlaying() {
    guard needsNowPlayingAnnouncement, hasNowPlaying() else { return }
    needsNowPlayingAnnouncement = false
    // A station is no song the server knows.
    guard !isLiveRadio else { return }
    // The lookup at song change may have failed offline, as for a queue
    // restored at launch.
    MainActor.assumeIsolated { loadStarred(refresh: true) }

    FloooViewModel.shared.reportPlayback(
      state: .starting, nowPlaying: self.nowPlaying, positionSeconds: self.pendingStartPosition)
  }

  /// Tells the server where the announced song stands; the ViewModel drops a
  /// playing report within 30 s of the last one.
  private func reportPlayback(_ state: PlaybackReportState, at position: Double? = nil) {
    guard !needsNowPlayingAnnouncement, hasNowPlaying(), !isLiveRadio
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

  func addPeriodicTimeObserver() {
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
      let isRunning = (self.player?.rate ?? 0) > 0

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
      if isRunning, step > 0, step <= 3 {
        self.secondsListened += step
        self.countStartPlayed(step)
        self.noteProgress()
      }
      self.lastObservedTime = currentTime

      // Half an hour without playback ends the listening session.
      if isRunning {
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
        self.precacheUpcoming()
      }

      self.qualifyIfDue()

      if Self.tickEndsSong(at: currentTime, duration: self.totalDuration, isRunning: isRunning) {
        self.finishCurrentSong()
      }
    }
  }

  /// Whether an observer tick ends the song: only while it plays, so a seek
  /// to the end while paused waits for Play, and only once the whole song
  /// was heard. An item shorter than its reported duration reports its own
  /// end (AVPlayerItemDidPlayToEndTime).
  static func tickEndsSong(at time: Double, duration: Double, isRunning: Bool) -> Bool {
    isRunning && duration.isFinite && duration > 0 && time >= duration
  }

  /// A song heard to its end was accepted, also when qualification did not
  /// run this time (counted before a relaunch, or joined late); a last tick
  /// may still owe it the count.
  func finishCurrentSong() {
    qualifyIfDue()
    acceptNowPlaying()
    nextSong()
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
  }

  func play() {
    playGeneration += 1
    let gen = playGeneration
    cancelSettle()
    pendingStart = PendingStart()
    MainActor.assumeIsolated { publishSiriTarget() }
    RequestLog.shared.note(
      "audio activate \(gen) playing=\(isPlaying) item=\(playerItem != nil)")
    AppPlatform.activateAudio { [weak self] success, error in
      // The callback may arrive off-main; playGeneration is only read or written
      // on the main queue.
      DispatchQueue.main.async {
        guard let self = self else { return }
        RequestLog.shared.note(
          "audio activated \(gen) success=\(success) current=\(self.playGeneration)"
            + " outputs=\(Self.routeOutputs)"
            + (error.map { " error=\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? ""))
        guard gen == self.playGeneration else { return }
        self.pendingStart?.isActivating = false
        // A dismissed device list completes without an error: the user said
        // no, so nothing tries again.
        if error != nil || !success {
          debugLog("Audio session activation failed: \(String(describing: error))")
          if error == nil {
            self.endStart()
          } else if self.resumeAfterInterruption {
            // A kept start tries again once the route is quiet, within its
            // resumes.
            self.armSettle()
          }
          return
        }
        // Playing from here: a later end of an interruption must not restart
        // music the user may pause meanwhile.
        self.resumeAfterInterruption = false

        if self.playerItem == nil, self.hasNowPlaying(), !self.isLiveRadio {
          self.isFinished = false
          self.isPlaying = true
          self.updateNowPlayingInfo(progress: self.progress, rate: 1.0)
          self.announceNowPlaying()
          self.reportPlayback(.playing)
          self.loadItem(at: self.pendingStartPosition)
          return
        }

        // A failed item cannot play, nor can one already counted as failed
        // (ready but silent); a fresh one gets one more chance.
        if let item = self.playerItem, item.status == .failed || item === self.countedFailedItem,
          self.hasNowPlaying()
        {
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
    // A mix still being built must not start behind a pause, nor during a
    // call that paused.
    startGeneration += 1
    endStart()
    // A pause ends a run of resumes; a stall after Play is a fresh one.
    resumedAtListened = nil
    endConnectionWait(because: "pause")
    cancelStall()
    // AVPlayer resumes a stalled item by waiting on its dead connection; Play
    // loads a fresh one where it stopped.
    if itemHasPlayed, currentSourceIsRemote, !isLiveRadio,
      player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    {
      pendingStartPosition = floor(lastObservedTime)
      RequestLog.shared.note("stall paused at \(Int(pendingStartPosition)) s, play reloads")
      detachItem()
    }
    player?.pause()
    reportPlayback(.paused)

    self.isPlaying = false
    self.updateNowPlayingInfo(progress: self.progress, rate: 0.0)
  }

  func stop() {
    reportStopped()
    playGeneration += 1
    // An activation it overtakes is not answered any more; the next play()
    // begins a fresh start.
    pendingStart?.isActivating = false
    cancelSettle()
    resumeAfterInterruption = false
    endConnectionWait(because: "stop")
    cancelStall()
    player?.pause()
    // No observer tick follows while paused, so the reset is applied here.
    // Starting the song over is a new listen, which may count again.
    pendingStartPosition = 0
    progress = 0
    currentTimeString = timeString(for: 0)
    hasQualified = false
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
    // The system's clock runs on from the last rate it was given.
    updateNowPlayingInfo(progress: 0, rate: 0.0)
    MainActor.assumeIsolated { NowPlayingTarget.current = nil }
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
      // A fresh grace period from the new position.
      cancelStall()
      if itemHasPlayed { armStallDeadline() } else { armLoadWatchdog() }
    }
    self.updateNowPlayingInfo(progress: progress, rate: isPlaying ? 1.0 : 0.0)
    if isPlaying { reportPlayback(.playing, at: target) }
  }

  func cyclePlaybackMode() {
    if self.playbackMode == PlaybackMode.defaultPlayback {
      self.playbackMode = PlaybackMode.repeatAlbum
    } else if self.playbackMode == PlaybackMode.repeatAlbum {
      self.playbackMode = PlaybackMode.repeatOnce
    } else {
      self.playbackMode = PlaybackMode.defaultPlayback
    }

    UserDefaultsManager.playbackMode = self.playbackMode
    precacheUpcoming()
  }

  // The play functions return whether playback started. An item without
  // songs (e.g. an album whose tracks are still loading) leaves the current
  // queue untouched, so callers only show Now Playing on success.

  @discardableResult
  func playItem<T: Playable>(item: T, startingAt idx: Int = 0) -> Bool {
    guard item.songs.indices.contains(idx) else { return false }
    beginUserStart()
    let queue = PlaybackService.shared.addToQueue(item: item)
    guard !queue.isEmpty else { return false }
    self.addToQueue(idx: idx, item: queue)
    return true
  }

  @discardableResult
  func shuffleItem<T: Playable>(item: T) -> Bool {
    var shuffledItem = item
    shuffledItem.songs.shuffle()
    return playItem(item: shuffledItem)
  }

  /// Starts something the user chose: a mix in flight and the old session
  /// are dropped.
  func beginUserStart() {
    startGeneration += 1
    reportStopped()
    resetSession()
  }

  /// Builds a smart mix and plays it, for Home's button and the intent. False
  /// while a mix is already being built, when none came together, or when the
  /// user started something else in the meantime.
  @MainActor func playSomething() async -> Bool {
    var record: MixRecord?
    let played = await playWhenBuilt {
      let mix = await SmartPlaybackService.shared.mix(count: 15, mode: .playSomething)
      record = mix.record
      return .smartShuffle(mix.songs)
    }
    if played, let record { RecommendationLog.shared.markPlayed(record) }
    return played
  }

  /// Plays an artist's top songs, for the intent; without top songs the
  /// artist's songs from the cached library, offline those on the watch,
  /// shuffled. False like `playSomething()`.
  @MainActor func playArtist(id: String, name: String) async -> Bool {
    await playWhenBuilt {
      // A fresh verdict: right after launch the monitor still assumes online,
      // and offline the top songs request could only time out.
      var online = await ConnectivityMonitor.shared.canStream()
      var songs: [Song] = []
      if online {
        let result = await withCheckedContinuation { continuation in
          RadioService.shared.getTopSongs(artistId: id) { continuation.resume(returning: $0) }
        }
        songs = (try? result.get()) ?? []
        // A failed request most likely means the link went; the monitor may
        // not know yet.
        if case .failure = result { online = false }
      }
      if songs.isEmpty {
        let keys = await SmartPlaybackService.shared.libraryIndex(allowSync: false).artistKeys
        let byArtist = { (library: [Song]) in
          library.filter { $0.isBy(artistId: id, name: name, keys: keys) }
        }
        // Offline only what is downloaded or cached can play. Online a cache
        // without the artist (a fresh login, an artist added since) is synced.
        let service = SmartPlaybackService.shared
        songs = byArtist(online ? await service.loadCachedLibrary().songs : await service.offlinePlayableSongs())
        if online, songs.isEmpty { songs = byArtist(await service.syncSongLibrary()) }
        // The sync may have failed because the link went.
        if songs.isEmpty { songs = byArtist(await service.offlinePlayableSongs()) }
        songs.shuffle()
      }
      return .artist(id: id, name: name, songs: songs)
    }
  }

  /// Builds a collection and plays it, unless one is already being built or
  /// the user started something else in the meantime.
  @MainActor private func playWhenBuilt(_ build: () async -> SongCollection) async -> Bool {
    guard !isGeneratingMix else { return false }
    isGeneratingMix = true
    let generation = startGeneration
    let item = await build()
    isGeneratingMix = false
    guard startGeneration == generation else { return false }
    return playItem(item: item)
  }

  func shuffleCurrentQueue() {
    guard hasNowPlaying() else { return }
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
      let current = self.queue[self.activeQueueIdx]
      self.queue = self.unshuffledQueue
      self.unshuffledQueue = []
      self.activeQueueIdx = self.queue.firstIndex(where: { $0 === current }) ?? 0
    }

    persistActiveIndex()
    persistShuffleOrder()
    precacheUpcoming()
  }

  private static let shuffleOrderKey = "queueShuffleOrder"

  /// Saves the shuffled order as positions in the persisted queue, which
  /// stays in the original order.
  func persistShuffleOrder() {
    guard isShuffling else {
      UserDefaults.standard.removeObject(forKey: Self.shuffleOrderKey)
      return
    }
    let order = queue.compactMap { item in unshuffledQueue.firstIndex { $0 === item } }
    UserDefaults.standard.set(order, forKey: Self.shuffleOrderKey)
  }

  /// Saves the current song's position in the persisted queue order, which is
  /// the unshuffled one, so a relaunch restores the song that was playing.
  func persistActiveIndex() {
    guard hasNowPlaying() else { return }

    var index = activeQueueIdx
    if isShuffling,
      let unshuffledIndex = unshuffledQueue.firstIndex(where: { $0 === nowPlaying })
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
    if playbackMode != PlaybackMode.repeatOnce, activeQueueIdx > 0 {
      activeQueueIdx -= 1
    }
    setNowPlaying()
  }

  func nextSong(userInitiated: Bool = false) {
    guard !isLiveRadio else { return }
    if userInitiated {
      logSkipIfAbandoned()
    }
    reportStopped()

    let isLast = activeQueueIdx >= queue.count - 1
    switch playbackMode {
    case PlaybackMode.repeatOnce:
      setNowPlaying()
    case PlaybackMode.repeatAlbum:
      activeQueueIdx = isLast ? 0 : activeQueueIdx + 1
      setNowPlaying()
    default:
      if isLast {
        autoPlayOrStop()
      } else {
        activeQueueIdx += 1
        setNowPlaying()
      }
    }
  }

  /// Caches the next two songs, so a dropout or a skip does not stop the
  /// music. Only once the current song played 10 s: a song skipped right
  /// away should not cost two downloads.
  func precacheUpcoming() {
    let upcoming = upcomingQueueIndices(2)
    // A song edited out of the next two stops downloading.
    StreamCacheManager.shared.cancelAllInFlight(keeping: Set(upcoming.compactMap { queue[$0].id }))
    guard hasTriggeredCache, !isLiveRadio else { return }
    for idx in upcoming {
      let entry = queue[idx]
      guard let id = entry.id, !id.isEmpty else { continue }
      AlbumService.shared.prefetchTranscodeDecision(songId: id)
      StreamCacheManager.shared.cacheSong(
        mediaFileId: id, originalSuffix: entry.suffix, from: entry)
    }
  }

  /// The queue indices that play after the current one, at most `count`:
  /// none on repeat one, wrapping around on repeat album, never the current.
  private func upcomingQueueIndices(_ count: Int) -> [Int] {
    guard queue.count > 1, playbackMode != PlaybackMode.repeatOnce else { return [] }
    let remaining =
      playbackMode == PlaybackMode.repeatAlbum
      ? queue.count - 1 : queue.count - 1 - activeQueueIdx
    return (0..<max(0, min(count, remaining))).map { (activeQueueIdx + 1 + $0) % queue.count }
  }

  deinit {
    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
    }
    player?.pause()
  }
}

// What the player screens show about the queue.
extension PlayerViewModel {
  func togglePlayback() {
    if isPlaying { pause() } else { play() }
  }

  /// The album of the song in the player, empty while the queue is.
  var nowPlayingAlbumId: String {
    hasNowPlaying() ? nowPlaying.albumId ?? "" : ""
  }

  /// A mix or its Keep Playing continuation.
  var isSmartMix: Bool {
    guard hasNowPlaying() else { return false }
    return nowPlaying.playbackOrigin.isMix
  }

  /// "Smart Mix", else the album or playlist the queue came from.
  var sourceName: String {
    guard hasNowPlaying() else { return "" }
    return isSmartMix ? "Smart Mix" : nowPlaying.contextName ?? ""
  }
}
