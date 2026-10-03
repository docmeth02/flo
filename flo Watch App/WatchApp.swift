//
//  WatchApp.swift
//  flo Watch App
//
//  Created for watchOS target
//

import AVFoundation
import SwiftUI

@main
struct FloWatchApp: App {
  init() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, policy: .longFormAudio)
    } catch {
      print("Failed to set audio session category: \(error)")
    }

    StreamCacheManager.shared.reconcile()
    // Earlier builds cached API requests with credentials in Cache.db.
    URLCache.shared.removeAllCachedResponses()

    // Deliver scrobbles queued in an earlier session; the outbox otherwise only
    // wakes up when the next listen fails.
    _ = ScrobbleQueueManager.shared
    // Request times count from here.
    _ = RequestLog.shared
    // Imports the server's play log when the app becomes active.
    _ = ListeningHistoryStore.shared
    // Journal rows older than its windows only take space.
    PlaybackJournal.shared.pruneOld()
    // Sends rating edits the server has not confirmed yet.
    _ = RatingStore.shared

    #if DEBUG
      SmartPlaybackService.shared.runDebugLaunchActions()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      WatchContentView()
    }
  }
}
