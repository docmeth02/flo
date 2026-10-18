//
//  WatchApp.swift
//  flo Watch App
//
//  Created for watchOS target
//

import AVFoundation
import SwiftUI
import WatchKit

/// Hands the download session's wake-ups to `DownloadSession`; everything
/// else is completed at once.
final class AppDelegate: NSObject, WKApplicationDelegate {
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refresh as WKURLSessionRefreshBackgroundTask:
        DownloadSession.shared.handle(refresh)
      case let snapshot as WKSnapshotRefreshBackgroundTask:
        snapshot.setTaskCompleted(
          restoredDefaultState: false, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}

@main
struct FloWatchApp: App {
  @WKApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, policy: .longFormAudio)
    } catch {
      debugLog("Failed to set audio session category: \(error)")
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
    // A relaunch for finished downloads delivers them to this session.
    _ = DownloadSession.shared

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
