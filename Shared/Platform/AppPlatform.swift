//
//  AppPlatform.swift
//  flo
//

import AVFoundation

#if os(watchOS)
  import WatchKit
#else
  import Network
  import UIKit
#endif

/// The few app and audio calls that differ between watchOS and iOS. Shared
/// code goes through these and imports neither WatchKit nor UIKit for them.
enum AppPlatform {
  #if os(watchOS)
    static let name = "watchOS"
    static let didBecomeActive = WKApplication.didBecomeActiveNotification
    /// Cover tiles are 36 to 100 points at 2x, so 200 px is the largest the
    /// watch shows.
    static let coverArtSize = 200
    /// The watch's streaming limit applies on every network.
    static let isOnCellular = false
    /// The output setup interrupts a start without an end (watchOS 26 with
    /// AirPods); the start is kept through it instead of pausing.
    static let keepsStartThroughInterruptions = true

    static var isInBackground: Bool {
      WKApplication.shared().applicationState == .background
    }

    /// The OS and its version for the diagnostics, e.g. "watchOS 26.6".
    @MainActor static var systemDescription: String {
      let device = WKInterfaceDevice.current()
      return "\(device.systemName) \(device.systemVersion)"
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
    /// Now Playing's cover is 322 points wide at 3x.
    static let coverArtSize = 1000
    static let keepsStartThroughInterruptions = false

    private static let path: NWPathMonitor = {
      let monitor = NWPathMonitor()
      monitor.start(queue: DispatchQueue(label: "flo.path"))
      return monitor
    }()

    /// On a cellular link without Wi-Fi or Ethernet.
    static var isOnCellular: Bool {
      let current = path.currentPath
      return current.usesInterfaceType(.cellular) && !current.usesInterfaceType(.wifi)
        && !current.usesInterfaceType(.wiredEthernet)
    }

    static var isInBackground: Bool {
      UIApplication.shared.applicationState == .background
    }

    @MainActor static var systemDescription: String {
      let device = UIDevice.current
      return "\(device.systemName) \(device.systemVersion)"
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
