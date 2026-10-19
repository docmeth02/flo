//
//  PlaySomethingNowIntent.swift
//  Ownwave
//

import AppIntents

/// Play Something from a widget or the Control Center control, without
/// opening the app. An audio playback intent runs in the app's process (the
/// system launches it in the background when needed), so the extension only
/// needs the type for its buttons. Siri and Shortcuts keep the one that opens
/// the app, `PlaySomethingIntent`.
struct PlaySomethingNowIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Something"
  static var description = IntentDescription("Plays a smart mix from your library.")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      // Signed out, a stale cache would build a mix the app cannot play.
      // The mix is awaited to the end: once it plays, audio keeps the
      // process alive.
      if AppModel.shared.auth.isLoggedIn { _ = await AppModel.shared.player.playSomething() }
    #endif
    return .result()
  }
}
