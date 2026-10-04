//
//  PlaySomethingIntent.swift
//  flo Watch App
//

import AppIntents

/// Play Something for Siri, Shortcuts and the Action Button. The mix is built
/// by the player that WatchContentView owns, so the intent only asks for it.
struct PlaySomethingIntent: AppIntent {
  static var title: LocalizedStringResource = "Play Something"
  static var description = IntentDescription("Plays a smart mix from your library.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    PlaySomethingRequest.post()
    return .result()
  }
}

/// The phrases are English; AppShortcuts.xcstrings holds their German
/// versions, since Siri on the watch only runs a phrase spoken exactly.
struct FloShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlaySomethingIntent(),
      phrases: ["Play something in \(.applicationName)"],
      shortTitle: "Play Something",
      systemImageName: "sparkles")
  }
}

extension Notification.Name {
  static let playSomethingRequested = Notification.Name("flo.playSomethingRequested")
}

/// A request WatchContentView has not taken yet. A launch by the intent can
/// run perform() before the view subscribed to the notification, so the view
/// also takes a pending request when it appears.
@MainActor
enum PlaySomethingRequest {
  private static var isPending = false

  static func post() {
    isPending = true
    NotificationCenter.default.post(name: .playSomethingRequested, object: nil)
  }

  /// True once per request.
  static func take() -> Bool {
    defer { isPending = false }
    return isPending
  }
}
