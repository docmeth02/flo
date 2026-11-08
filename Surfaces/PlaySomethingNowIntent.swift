//
//  PlaySomethingNowIntent.swift
//  Ownwave
//

import AppIntents

/// Play Something from a widget or the Control Center control, without
/// opening the app. An audio playback intent runs in the app's process (the
/// system launches it in the background when needed), so the extension only
/// needs the type for its buttons. Siri and Shortcuts use
/// `PlaySomethingIntent`, which plays the same way on the iPhone.
struct PlaySomethingNowIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Something"
  static var description = IntentDescription("Plays a smart mix from your library.")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      // The mix is awaited to the end: once it plays, audio keeps the process
      // alive. A widget has nowhere to say why nothing played.
      try? await AppModel.shared.perform(.something)
    #endif
    return .result()
  }
}
