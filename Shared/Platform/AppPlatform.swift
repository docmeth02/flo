//
//  AppPlatform.swift
//  flo
//

import AVFoundation

#if os(watchOS)
  import WatchKit
#else
  import UIKit
#endif

/// The few app and audio calls that differ between watchOS and iOS. Shared
/// code goes through these and imports neither WatchKit nor UIKit for them.
enum AppPlatform {
  #if os(watchOS)
    static let name = "watchOS"
    static let didBecomeActive = WKApplication.didBecomeActiveNotification

    static var isInBackground: Bool {
      WKApplication.shared().applicationState == .background
    }

    /// Activates the session and connects an output, asking for a device
    /// when none is in reach. Reports `false` without an error when the
    /// user dismissed the device list.
    static func activateAudio(_ done: @escaping (Bool, Error?) -> Void) {
      AVAudioSession.sharedInstance().activate(options: [], completionHandler: done)
    }
  #else
    static let name = "iOS"
    static let didBecomeActive = UIApplication.didBecomeActiveNotification

    static var isInBackground: Bool {
      UIApplication.shared.applicationState == .background
    }

    static func activateAudio(_ done: @escaping (Bool, Error?) -> Void) {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        done(true, nil)
      } catch {
        done(false, error)
      }
    }
  #endif
}
