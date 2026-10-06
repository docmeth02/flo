//
//  WatchPlayerViewModel+Debug.swift
//  flo Watch App
//

#if DEBUG
  import AVFoundation

  // Simulator verification only. FLO_DEBUG_PLAY_SOMETHING=1 starts a smart mix
  // a few seconds after launch; FLO_DEBUG_BROKEN_FIRST=1 puts an unknown song
  // first; FLO_DEBUG_SEEK=<0...1> then seeks the first track to that
  // position; the queue state is logged along the way. FLO_DEBUG_BITRATE=<kbps>
  // sets the bitrate limit to one Settings offers (it stays in the simulator's
  // defaults), FLO_DEBUG_RESUME_AT=<s> breaks the remote stream once it reaches that
  // position, and FLO_DEBUG_DUMP_LOG=<s> logs the request log at that time.
  // FLO_DEBUG_RATE=<playbackID>:<0-5> rates a song at launch;
  // FLO_DEBUG_SKIP_AFTER=<s> presses next once the first song was heard that long.
  // FLO_DEBUG_STALL=<s> treats the remote item as stalled <s> seconds after the
  // mix started (the simulator never stalls); FLO_DEBUG_STALL=<s>:offline
  // enters the connection wait instead.
  extension WatchPlayerViewModel {
    func runDebugLaunchActions() {
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
      runQueueDebugAction()
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

      if let stall = env["FLO_DEBUG_STALL"]?.split(separator: ":"),
        let after = stall.first.flatMap({ Double($0) })
      {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 + after) { [weak self] in
          guard let self, self.isPlaying, self.currentSourceIsRemote, let item = self.playerItem
          else {
            debugLog("stall: no remote item playing")
            return
          }
          debugLog("simulating stall at \(self.lastObservedTime)")
          if stall.last == "offline" {
            self.enterConnectionWait(cause: "debug")
          } else {
            self.recoverStalledItem(item, trackId: self.nowPlaying.id)
          }
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
          if env["FLO_DEBUG_BROKEN_FIRST"] == "1" {
            // A song id the server does not know ahead of a mix, to exercise
            // failed streams.
            let songs = await SmartPlaybackService.shared.generateMix(
              count: 15, mode: .playSomething)
            guard let first = songs.first else { return debugLog("mix generated: 0 songs") }
            let broken = Song(
              id: "broken-\(first.id)", title: "Broken", albumId: first.albumId,
              albumName: first.albumName, artist: first.artist, trackNumber: 1, discNumber: 1,
              bitRate: 0, sampleRate: 0, suffix: first.suffix, duration: first.duration,
              mediaFileId: "broken-\(first.id)")
            self.playItem(
              item: SongCollection(id: "debug", name: "Debug", songs: [broken] + songs),
              isFromLocal: false)
          } else {
            let played = await self.playSomething()
            debugLog("play something: \(played) queue=\(self.queue.count)")
          }

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
