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
  }

  var body: some Scene {
    WindowGroup {
      WatchContentView()
    }
  }
}
