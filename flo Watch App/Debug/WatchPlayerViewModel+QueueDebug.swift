//
//  WatchPlayerViewModel+QueueDebug.swift
//  flo Watch App
//

#if DEBUG
  import Foundation

  // Simulator verification only. FLO_DEBUG_QUEUE edits the restored queue
  // five seconds after launch: next:<songId> (from the cached library, else
  // a copy of the queue's last song), append:<albumId> (its songs from the
  // cached library), remove:<index>, undo:<index> (remove, then Undo) or
  // move:<index>, indices in play order. The play order and the stored
  // positions are logged after each step.
  extension WatchPlayerViewModel {
    func runQueueDebugAction() {
      guard let value = ProcessInfo.processInfo.environment["FLO_DEBUG_QUEUE"] else { return }
      let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1] : ""
      let index = Int(argument)

      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        Task { @MainActor in
          let library = await SmartPlaybackService.shared.loadCachedLibrary().songs
          self.logQueue("before")
          let changed: Bool
          switch parts[0] {
          case "next":
            let song =
              library.first { $0.playbackID == argument } ?? self.queue.last.map(Song.init(from:))
            changed = song.map { self.playNext([$0], context: "Debug") } ?? false
          case "append":
            let songs = library.filter { $0.albumId == argument }
              .sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
            changed = self.appendToQueue(songs, context: "Debug")
          case "remove":
            changed = index.flatMap(self.removeFromQueue(at:)) != nil
          case "undo":
            let removed = index.flatMap(self.removeFromQueue(at:))
            self.logQueue("removed")
            changed = removed.map { self.undoRemove($0) } ?? false
          case "move":
            changed = index.map { self.moveToNext(at: $0) } ?? false
          default:
            changed = false
          }
          self.logQueue("\(value) changed=\(changed)")
        }
      }
    }

    private func logQueue(_ label: String) {
      debugLog(
        "queue \(label): shuffling=\(isShuffling) current=\(activeQueueIdx) "
          + "storedIdx=\(UserDefaultsManager.queueActiveIdx)")
      for (index, item) in queue.enumerated() {
        debugLog("  play \(index) \(item.songName ?? "?")")
      }
      for item in PlaybackService.shared.getQueue() {
        debugLog("  stored \(item.position) \(item.songName ?? "?")")
      }
    }
  }
#endif
