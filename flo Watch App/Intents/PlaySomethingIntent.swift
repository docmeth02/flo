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
    PlayRequest.post(.something)
    return .result()
  }
}

/// Plays an artist's top songs, or offline their songs on the watch.
struct PlayArtistIntent: AppIntent {
  static var title: LocalizedStringResource = "Play Artist"
  static var description = IntentDescription("Plays an artist's top songs.")
  static var openAppWhenRun = true

  @Parameter(title: "Artist")
  var artist: ArtistAppEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    PlayRequest.post(.artist(id: artist.id, name: artist.name))
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
    AppShortcut(
      intent: PlayArtistIntent(),
      phrases: ["Play \(\.$artist) in \(.applicationName)"],
      shortTitle: "Play Artist",
      systemImageName: "music.mic")
  }
}

extension Notification.Name {
  static let playRequested = Notification.Name("flo.playRequested")
}

/// What an intent asked the app to play. WatchContentView takes it; a launch
/// by the intent can run perform() before the view subscribed to the
/// notification, so the view also takes a pending request when it appears.
enum PlayRequest {
  case something
  case artist(id: String, name: String)

  @MainActor private static var pending: PlayRequest?

  @MainActor static func post(_ request: PlayRequest) {
    pending = request
    NotificationCenter.default.post(name: .playRequested, object: nil)
  }

  /// The pending request, once.
  @MainActor static func take() -> PlayRequest? {
    defer { pending = nil }
    return pending
  }
}
