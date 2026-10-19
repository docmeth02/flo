//
//  OwnwaveApp.swift
//  Ownwave
//

import SwiftUI
import UIKit

/// Hands each background session's events to its owner: the phone's
/// downloads or the songs on their way to the watch.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    if identifier == WatchSend.identifier {
      WatchSend.shared.handleBackgroundEvents(completion: completionHandler)
    } else {
      DownloadSession.shared.handleBackgroundEvents(completion: completionHandler)
    }
  }
}

@main
struct OwnwaveApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    AppLaunch.warmUp()
    _ = WatchSend.shared
    WatchLink.shared.activate()
    WidgetPublisher.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
