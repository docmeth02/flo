//
//  WatchPlayerViewModel+Recovery.swift
//  flo
//

import AVFoundation
import Combine

// Item loading, buffering, stalls, the connection wait and failed streams.
extension WatchPlayerViewModel {
  /// Tracks the current item's loading state for both songs and radio.
  func observeItemStatus(trackId: String?) {
    let item = playerItem
    playerItemObservation = playerItem?.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] status in
        // A late report for a replaced item must not touch the new one's flags.
        guard let self = self, let item, item === self.playerItem else { return }
        switch status {
        case .readyToPlay:
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
          break
        }
      }
  }

  func observeBuffering() {
    bufferingObservation = player?.publisher(for: \.timeControlStatus)
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        guard let self else { return }
        let waitReason = self.player?.reasonForWaitingToPlay.map { " \($0.rawValue)" } ?? ""
        RequestLog.shared.note("audio player \(status.rawValue)\(waitReason)")
        let isWaiting = status == .waitingToPlayAtSpecifiedRate
        if isWaiting { self.armStallDeadline() }
        guard isWaiting != self.isBuffering else { return }
        debugLog("buffering \(isWaiting)")
        self.isBuffering = isWaiting
      }
  }

  /// An on-the-fly transcode stays connected while it plays, because AVPlayer
  /// stops reading once a little is buffered, and a connection that sits idle
  /// can be cut on the way (a reverse proxy's send timeout, nginx closes one
  /// after 60 s by default, or the cellular link). Asking for the whole rest
  /// of the song fetches it in one go; at the transcode's bitrate that is a
  /// few megabytes. A direct play is left to AVPlayer: it arrives at full
  /// speed anyway, and an original file can be large. Logs once when nearly
  /// all of it is buffered without a gap; a transcode of unknown length is
  /// timed from its bytes and can end a little short.
  private func bufferWholeSong(of item: AVPlayerItem, from offset: Double) {
    guard totalDuration.isFinite, totalDuration > offset else { return }
    let length = totalDuration - offset
    item.preferredForwardBufferDuration = length
    let attachedAt = Date()
    bufferGrewAt = attachedAt
    var loadedEnd = 0.0
    loadedRangesObservation = item.publisher(for: \.loadedTimeRanges)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] ranges in
        guard let self, let item, item === self.playerItem else { return }
        let end = ranges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.max() ?? 0
        if end > loadedEnd {
          loadedEnd = end
          self.bufferGrewAt = Date()
        }
        guard let ahead = Self.bufferedAhead(of: item),
          item.currentTime().seconds + ahead >= length * 0.9
        else { return }
        RequestLog.shared.note(
          String(
            format: "player buffered through %.0f of %.0f s after %.1f s",
            item.currentTime().seconds + ahead, length, Date().timeIntervalSince(attachedAt)))
        self.loadedRangesObservation = nil
      }
  }

  /// Seconds buffered without a gap from the playhead on; loaded ranges can
  /// have holes.
  private static func bufferedAhead(of item: AVPlayerItem) -> Double? {
    let now = item.currentTime()
    return item.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(now) }
      .map { CMTimeRangeGetEnd($0).seconds - now.seconds }
  }

  /// Gives a remote song that stopped for data after it had played
  /// `stallTimeout` to move on. One deadline per item, ended by progress, a
  /// pause, a seek or another item; a pending settle postpones it.
  func armStallDeadline() {
    guard stallDeadline == nil, isPlaying, itemHasPlayed, currentSourceIsRemote, !isLiveRadio,
      let item = playerItem, player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    else { return }
    let trackId = nowPlayingId
    let ahead = Self.bufferedAhead(of: item).map { String(format: "%.1f s", $0) } ?? "-"
    // A transcode still loading: how long ago its data last grew.
    let dataAge =
      loadedRangesObservation != nil ? bufferGrewAt.map { Date().timeIntervalSince($0) } : nil
    RequestLog.shared.note(
      "stall armed at \(Int(lastObservedTime)) s ahead=\(ahead)"
        + (dataAge.map { String(format: " data=%.0f s", $0) } ?? "")
        + " reason=" + (player?.reasonForWaitingToPlay?.rawValue ?? "-"))
    let deadline = DispatchWorkItem { [weak self, weak item] in
      guard let self, let item, item === self.playerItem else { return }
      self.stallDeadline = nil
      if self.settleWork != nil {
        self.armStallDeadline()
        return
      }
      guard self.isPlaying, self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
      else { return }
      RequestLog.shared.note("stall fired at \(Int(self.lastObservedTime)) s")
      self.recoverStalledItem(item, trackId: trackId)
    }
    stallDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout, execute: deadline)
    if let dataAge, let grewAt = bufferGrewAt {
      reloadCutTranscode(
        item, trackId: trackId, grewAt: grewAt, after: max(0, Self.stallTimeout - dataAge))
    }
  }

  /// A transcode short of its end whose data stopped coming in lost its
  /// connection, so its deadline counts from the last data: `stallTimeout`
  /// after it, the song reloads if the server answers. Without an answer, or
  /// with new data meanwhile, the stall deadline stays, so a dead spot is
  /// waited out as before.
  private func reloadCutTranscode(
    _ item: AVPlayerItem, trackId: String?, grewAt: Date, after delay: TimeInterval
  ) {
    let check = noProgressCheck
    Task { @MainActor [weak self, weak item] in
      try? await Task.sleep(for: .seconds(delay))
      guard self?.noProgressCheck == check, self?.bufferGrewAt == grewAt else { return }
      let reachable = await ConnectivityMonitor.shared.canStream(maxAge: 0)
      guard reachable, let self, let item, item === self.playerItem, self.isPlaying,
        self.noProgressCheck == check, self.settleWork == nil,
        self.loadedRangesObservation != nil, self.bufferGrewAt == grewAt,
        self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
      else { return }
      RequestLog.shared.note("stall cut at \(Int(self.lastObservedTime)) s")
      self.cancelStall()
      self.handleStreamFailure(trackId: trackId, item: item)
    }
  }

  /// A stalled song reloads where it stopped, or waits while the server is
  /// out of reach. Internal for the debug hooks.
  func recoverStalledItem(_ item: AVPlayerItem, trackId: String?) {
    handleNoProgress(of: item, cause: "stall") { [weak self, weak item] in
      self?.handleStreamFailure(trackId: trackId, item: item)
    }
  }

  /// Ends a stall deadline and any connectivity check started for it; a
  /// pause, a seek or another item gives the song a fresh start.
  func cancelStall() {
    stallDeadline?.cancel()
    stallDeadline = nil
    noProgressCheck += 1
  }

  /// An item that made no progress in time: a remote song waits while the
  /// server is out of reach, otherwise `broken` handles the item. Progress, a
  /// pause, a seek or another item during the probe end it.
  private func handleNoProgress(
    of item: AVPlayerItem, cause: String, broken: @escaping () -> Void
  ) {
    guard currentSourceIsRemote else {
      broken()
      return
    }
    let check = noProgressCheck
    Task { @MainActor [weak self, weak item] in
      let reachable = await ConnectivityMonitor.shared.canStream(maxAge: 0)
      // Playing again before the next progress tick counts as progress too.
      guard let self, let item, item === self.playerItem, self.isPlaying,
        self.noProgressCheck == check, self.player?.timeControlStatus != .playing
      else { return }
      if reachable {
        broken()
      } else {
        self.enterConnectionWait(cause: cause)
      }
    }
  }

  /// The current item played on: its load and any stall are over.
  func noteProgress() {
    itemHasPlayed = true
    consecutiveFailures = 0
    reloadedFailedTrackId = nil
    loadWatchdog?.cancel()
    cancelStall()
    endConnectionWait(because: "playing")
  }

  /// Keeps the song, its position and the wish to play while the server is
  /// out of reach. Probes every `connectionProbeInterval`, reloads once a
  /// probe reaches the server and pauses after `connectionWaitLimit`.
  /// Internal for the debug hooks.
  func enterConnectionWait(cause: String) {
    let position = itemHasPlayed ? floor(lastObservedTime) : pendingStartPosition
    detachItem()
    pendingStartPosition = position
    isMediaLoading = false
    isMediaFailed = false
    // The system's elapsed clock stops with the song.
    updateNowPlayingInfo(progress: progress, rate: 0)
    guard connectionWait == nil else {
      connectionWait?.isReloading = false
      RequestLog.shared.note("connection wait goes on at \(Int(position)) s cause=\(cause)")
      return
    }
    let timer = Timer.scheduledTimer(
      withTimeInterval: Self.connectionProbeInterval, repeats: true
    ) { [weak self] _ in self?.connectionWaitTick() }
    connectionWait = ConnectionWait(since: Date(), timer: timer)
    RequestLog.shared.note("connection wait entered at \(Int(position)) s cause=\(cause)")
    ConnectivityMonitor.shared.probeIfIdle()
  }

  private func connectionWaitTick() {
    guard let wait = connectionWait else { return }
    guard Date().timeIntervalSince(wait.since) < Self.connectionWaitLimit else {
      endConnectionWait(because: "gave up")
      pause()
      return
    }
    RequestLog.shared.note("connection wait probe")
    ConnectivityMonitor.shared.probeIfIdle()
  }

  /// The server answered: a waiting song loads again where it was, unless a
  /// load is already under way.
  func reloadAfterConnectionWait() {
    guard let wait = connectionWait, !wait.isReloading else { return }
    RequestLog.shared.note("connection wait reload at \(Int(pendingStartPosition)) s")
    loadItem(at: pendingStartPosition)
  }

  func endConnectionWait(because cause: String) {
    guard let wait = connectionWait else { return }
    wait.timer.invalidate()
    connectionWait = nil
    RequestLog.shared.note("connection wait left: \(cause)")
  }

  /// A player whose item failed can end up failed itself, and a failed
  /// AVPlayer refuses every later item; start over with a fresh one. Callers
  /// have already removed the time observer from the old player.
  func replacePlayerIfFailed() {
    guard let old = player, old.status == .failed else { return }
    player = AVPlayer()
    debugLog("replaced failed player")
  }

  /// Detaches every observer tied to the current item.
  func tearDownItemObservers() {
    if let timeObserverToken = timeObserverToken {
      player?.removeTimeObserver(timeObserverToken)
      self.timeObserverToken = nil
    }
    playerItemObservation?.cancel()
    playbackEndObservation?.cancel()
    playbackEndObservation = nil
    playbackFailureObservation = nil
    accessLogObservation = nil
    loadedRangesObservation = nil
    loadWatchdog?.cancel()
    cancelStall()
  }

  /// Removes the current item and its observers; a stream source still being
  /// resolved for it is dropped when it arrives.
  func detachItem() {
    loadGeneration += 1
    tearDownItemObservers()
    player?.replaceCurrentItem(with: nil)
    playerItem = nil
    itemHasPlayed = false
    streamOffset = 0
  }

  /// Attaches the now playing song's item, starting at `position` seconds of
  /// the track: a transcode is started there by the server, anything else is
  /// seeked there. Remote songs wait for the server's transcode decision.
  func loadItem(at position: Double) {
    guard hasNowPlaying(), !isLiveRadio else { return }
    detachItem()
    replacePlayerIfFailed()
    pendingStartPosition = position
    isMediaLoading = true
    isMediaFailed = false
    connectionWait?.isReloading = true

    let generation = loadGeneration
    let trackId = nowPlaying.id
    let songId = trackId ?? ""

    if let fileURL = AlbumService.shared.localFileURL(mediaFileId: songId) {
      attachItem(
        url: fileURL, trackId: trackId, isRemote: false, isTranscoded: false, offset: 0,
        seekTo: position)
      return
    }

    let suffix = nowPlaying.suffix
    Task { @MainActor [weak self] in
      let result = await AlbumService.shared.resolveStreamSource(
        songId: songId, originalSuffix: suffix, offset: Int(position))
      guard let self, self.loadGeneration == generation, self.isCurrentTrack(trackId) else { return }
      // Paused, Play asks again.
      if case .failure(.unavailable) = result {
        self.isMediaLoading = false
        if self.isPlaying { self.enterConnectionWait(cause: "no stream source") }
        return
      }
      guard case .success(let source) = result, let url = URL(string: source.url) else {
        self.isMediaLoading = false
        self.isMediaFailed = true
        self.skipFailedTrack(trackId: trackId)
        return
      }

      let startsAtOffset = source.isTranscoded && position > 0
      self.attachItem(
        url: url, trackId: trackId, isRemote: true, isTranscoded: source.isTranscoded,
        offset: startsAtOffset ? floor(position) : 0, seekTo: startsAtOffset ? nil : position)
    }
  }

  private func attachItem(
    url: URL, trackId: String?, isRemote: Bool, isTranscoded: Bool, offset: Double,
    seekTo position: Double?
  ) {
    let item = AVPlayerItem(url: url)
    if isTranscoded { bufferWholeSong(of: item, from: offset) }
    playerItem = item
    player?.replaceCurrentItem(with: item)
    streamOffset = offset
    currentSourceIsRemote = isRemote
    currentSourceIsTranscoded = isTranscoded

    observeItemStatus(trackId: trackId)

    // A server that never answers leaves the item loading forever without
    // reporting .failed, and a stream can also break or hang mid-song; the
    // load watchdog and the stall deadline catch the silent cases, a break
    // resumes, waits for the server or skips.
    playbackFailureObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] notification in
        self?.handleStreamFailure(
          trackId: trackId, item: item,
          error: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
      }

    // What the player itself saw of the stream: how long it took to start,
    // stalls and errors.
    accessLogObservation = NotificationCenter.default
      .publisher(for: .AVPlayerItemNewAccessLogEntry, object: item)
      .merge(
        with: NotificationCenter.default.publisher(
          for: .AVPlayerItemNewErrorLogEntry, object: item))
      .receive(on: DispatchQueue.main)
      .sink { [weak item] notification in
        if notification.name == .AVPlayerItemNewErrorLogEntry {
          guard let event = item?.errorLog()?.events.last else { return }
          RequestLog.shared.note(
            "player error \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "")")
        } else if let event = item?.accessLog()?.events.last {
          RequestLog.shared.note(
            String(
              format: "player access startup=%.1f transfer=%.1f stalls=%d kbps=%.0f",
              event.startupTime, event.transferDuration, event.numberOfStalls,
              event.observedBitrate / 1000))
        }
      }

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
        self.finishCurrentSong()
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
    if isRemote {
      RequestLog.shared.note("player stream offset=\(Int(offset))\(isTranscoded ? " transcode" : "")")
    }
  }

  /// A stream that breaks mid-song resumes where it was instead of skipping
  /// ahead: a transcode restarts there, direct play seeks there. Failing to
  /// load, or breaking again within 30 s of the last resume, counts as failed.
  /// A broken connection waits for the server instead. `error` is the
  /// failure notification's; the item's own error is used without one.
  private func handleStreamFailure(trackId: String?, item: AVPlayerItem?, error: Error? = nil) {
    // KVO and the failure notification can both report the same item, and a
    // late report can arrive for an item already replaced.
    guard let item, item === playerItem else { return }
    // The load watchdog already counted this item and scheduled the skip.
    guard item !== countedFailedItem else { return }
    // Only the current queue entry's remote song is waited for, reloaded or
    // resumed; anything else that fails is skipped.
    let remoteSong = isCurrentTrack(trackId) && !isLiveRadio && currentSourceIsRemote
    // The server may no longer accept the decision's token.
    if remoteSong, let trackId {
      AlbumService.shared.forgetTranscodeDecision(songId: trackId)
    }
    if remoteSong, isPlaying,
      ConnectivityMonitor.isConnectionError(error ?? item.error)
        || !ConnectivityMonitor.shared.isServerReachable
    {
      enterConnectionWait(cause: "stream error")
      return
    }

    // Paused, the dead item is dropped so that Play loads the song again where
    // it was; its status may still read ready, which play() would otherwise
    // trust. A song that never got going is asked for once more: the server
    // rejects a decision's token after a rescan touched the file.
    if remoteSong, !isPlaying {
      if lastObservedTime > 5 { pendingStartPosition = floor(lastObservedTime) }
      detachItem()
      isMediaFailed = true
      return
    }
    if remoteSong, lastObservedTime <= 5, restartedTrackId != trackId {
      restartedTrackId = trackId
      loadItem(at: pendingStartPosition)
      return
    }
    guard remoteSong, isPlaying, lastObservedTime > 5,
      resumedAtListened.map({ secondsListened - $0 >= 30 }) ?? true
    else {
      isMediaFailed = true
      skipFailedTrack(trackId: trackId)
      return
    }

    let position = floor(lastObservedTime)
    resumedAtListened = secondsListened
    RequestLog.shared.note("stream resume at \(Int(position)) s")
    loadItem(at: position)
  }

  /// Treats an item that has not played after `loadTimeout` of trying as
  /// failed, or as a connection wait while the server is out of reach. A user
  /// who paused in the meantime is left alone, and so is a ready item the
  /// player is not waiting for (the system paused it).
  func armLoadWatchdog() {
    loadWatchdog?.cancel()
    guard let item = playerItem, !itemHasPlayed, !isLiveRadio else { return }

    let trackId = nowPlayingId
    let watchdog = DispatchWorkItem { [weak self, weak item] in
      guard let self = self, self.isPlaying, let item = item, self.playerItem === item,
        !self.itemHasPlayed
      else { return }
      if self.settleWork != nil {
        self.armLoadWatchdog()
        return
      }
      guard item.status != .readyToPlay
        || self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
      else { return }
      self.handleNoProgress(of: item, cause: "load timeout") { [weak self, weak item] in
        // A slow cell can leave a ready item silent; it is asked for once
        // more before it counts as failed.
        if item?.status == .readyToPlay {
          self?.handleStreamFailure(trackId: trackId, item: item)
        } else {
          self?.player?.pause()
          self?.skipFailedTrack(trackId: trackId)
        }
      }
    }
    loadWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: watchdog)
  }

  /// A failed stream (deleted file, transcoder error, corrupt cache) never
  /// reaches its end, so nothing would advance and playback would sit silent.
  /// Skip ahead after a moment, but stop after a few failures in a row so a
  /// broken library does not burn through the whole queue; an unreachable
  /// server is waited for instead.
  private func skipFailedTrack(trackId: String?) {
    loadWatchdog?.cancel()
    // Paused playback stays paused; pressing Play reloads the failed item.
    guard isPlaying, isCurrentTrack(trackId),
      !isLiveRadio, playerItem == nil || playerItem !== countedFailedItem
    else {
      return
    }
    endConnectionWait(because: "song failed")
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
      guard let self = self, self.playGeneration == generation, self.isCurrentTrack(trackId)
      else { return }
      self.nextSong()
    }
  }
}
