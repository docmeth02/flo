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

    // Deliver scrobbles queued in an earlier session; the outbox otherwise only
    // wakes up when the next listen fails.
    _ = ScrobbleQueueManager.shared
    // Request times count from here.
    _ = RequestLog.shared
    // Imports the server's play log when the app becomes active.
    _ = ListeningHistoryStore.shared
  }

  var body: some Scene {
    WindowGroup {
      WatchContentView()
    }
  }
}
