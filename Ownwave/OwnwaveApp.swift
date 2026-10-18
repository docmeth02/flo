//
//  OwnwaveApp.swift
//  Ownwave
//

import SwiftUI
import UIKit

/// Hands the download session's background events to `DownloadSession`.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    DownloadSession.shared.handleBackgroundEvents(completion: completionHandler)
  }
}

@main
struct OwnwaveApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
