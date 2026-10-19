//
//  WatchApp.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// Hands the download session's wake-ups to `DownloadSession` and the
/// iPhone link's to `PhoneLink`; everything else is completed at once.
final class AppDelegate: NSObject, WKApplicationDelegate {
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refresh as WKURLSessionRefreshBackgroundTask:
        DownloadSession.shared.handleBackgroundEvents {
          refresh.setTaskCompletedWithSnapshot(false)
        }
      case let link as WKWatchConnectivityRefreshBackgroundTask:
        MainActor.assumeIsolated { PhoneLink.shared.hold(link) }
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
    AppLaunch.warmUp()
    PhoneLink.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      WatchContentView()
    }
  }
}
