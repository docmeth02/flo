//
//  AppLaunch.swift
//  flo
//

import AVFoundation

/// What both apps do once at launch, before the first screen.
enum AppLaunch {
  @MainActor static func warmUp() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, policy: .longFormAudio)
    } catch {
      debugLog("Failed to set audio session category: \(error)")
    }

    // Starts the phone's network path monitor, so the first stream already
    // knows whether it is on cellular.
    _ = AppPlatform.isOnCellular
    StreamCacheManager.shared.reconcile()
    // Responses carry credentials, which must not stay in the shared disk cache.
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
    // Restores the played mixes, and is there to forget them on a logout.
    _ = RecommendationLog.shared
    // A relaunch for finished downloads delivers them to this session.
    _ = DownloadSession.shared

    #if DEBUG
      SmartPlaybackService.shared.runDebugLaunchActions()
    #endif
  }
}
