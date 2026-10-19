//
//  PlayerViewModel+KeepPlaying.swift
//  flo
//

import Foundation

// Skips, qualification, the listening session and the Keep Playing mix.
extension PlayerViewModel {
  /// Pressing next on a barely heard song is a negative signal for smart
  /// shuffle. Only early, user-initiated abandonment counts: natural track
  /// ends, radio, repeat modes that restart the same track and accidental
  /// starts under five seconds do not.
  func logSkipIfAbandoned() {
    guard self.hasNowPlaying(), !self.isLiveRadio else { return }
    guard !self.hasQualified else { return }

    let restartsSameTrack =
      self.playbackMode == PlaybackMode.repeatOnce
      || (self.queue.count == 1 && self.playbackMode != PlaybackMode.defaultPlayback)
    guard !restartsSameTrack else { return }

    guard self.totalDuration.isFinite, self.totalDuration > 0,
      self.secondsListened >= 5, self.progress < 0.3
    else { return }

    PlaybackJournal.shared.recordSkip(
      self.nowPlaying, origin: self.nowPlaying.playbackOrigin,
      listenedSeconds: self.secondsListened)
  }

  /// Something the user started, a logout or a long break ends the session.
  func resetSession() {
    sessionStartedAt = nil
    lastAcceptedSong = nil
    anchorGenres = []
  }

  /// Navidrome's rule: a play counts after half the song or four minutes of
  /// listening, whichever comes first; seeking ahead does not count. Runs
  /// on main: journal writes stay on the view context's queue and the
  /// submission is asynchronous inside the service.
  func qualifyIfDue() {
    guard !hasQualified, hasNowPlaying(), totalDuration.isFinite,
      totalDuration > 0, secondsListened >= min(0.5 * totalDuration, 240)
    else { return }
    hasQualified = true
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
  func acceptNowPlaying() {
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

  func autoPlayOrStop() {
    guard UserDefaultsManager.keepPlaying, hasNowPlaying() else {
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
      let (songs, record) = await SmartPlaybackService.shared.mix(
        count: 10,
        mode: .keepPlaying(
          SmartPlaybackService.KeepPlayingContext(
            seed: seed, anchorGenres: anchorGenres, sessionMinutes: sessionMinutes,
            queueIds: queueIds)))

      await MainActor.run { [weak self] in
        guard let self = self else { return }
        self.isAutoContinuing = false

        // Discard the mix if the user started something else while it was
        // being generated — the ordered queue contents are compared too, so a
        // new queue that happens to start on the same song is not overwritten.
        guard self.isCurrentTrack(lastPlayedId), self.playGeneration == generation
        else { return }
        guard self.queue.compactMap({ $0.id }) == queueIdList, UserDefaultsManager.keepPlaying
        else {
          // Songs queued while the mix was built play instead of it; with
          // none and Keep Playing turned off meanwhile, playback ends.
          if self.queue.indices.contains(self.activeQueueIdx + 1) {
            self.nextSong()
          } else {
            self.stop()
          }
          return
        }

        guard !songs.isEmpty else {
          self.stop()
          return
        }
        debugLog("keep playing: \(songs.count) songs follow")

        let autoPlay = SongCollection.keepPlaying(songs)
        // A mix that could not be stored ends playback like an empty one.
        let queue = PlaybackService.shared.addToQueue(item: autoPlay)
        guard !queue.isEmpty else {
          self.stop()
          return
        }
        // Through addToQueue, so shuffle state and failure counts reset like
        // for any other new queue.
        self.addToQueue(idx: 0, item: queue)
        if let record { RecommendationLog.shared.markPlayed(record) }
      }
    }
  }
}
