//
//  PlaySomethingIntent.swift
//  flo
//

import AppIntents

/// Play Something for Siri, Shortcuts and the Action Button. The iPhone plays
/// it in the background, also while locked; the watch opens the app, whose
/// audio activation may need to show the route picker.
struct PlaySomethingIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Something"
  static var description = IntentDescription("Plays a smart mix from your library.")
  // A literal per platform: the intent metadata is extracted at build time
  // and cannot evaluate an expression.
  #if os(watchOS)
    static var openAppWhenRun = true
  #else
    static var openAppWhenRun = false
  #endif

  @MainActor
  func perform() async throws -> some IntentResult {
    try await PlayRequest.run(.something)
    return .result()
  }
}

/// Plays an artist's top songs, or offline their songs on the device.
struct PlayArtistIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Artist"
  static var description = IntentDescription("Plays an artist's top songs.")
  #if os(watchOS)
    static var openAppWhenRun = true
  #else
    static var openAppWhenRun = false
  #endif

  @Parameter(title: "Artist")
  var artist: ArtistAppEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    try await PlayRequest.run(.artist(id: artist.id, name: artist.name))
    return .result()
  }
}

/// The phrases are English; AppShortcuts.xcstrings holds their German
/// versions, since Siri on the watch only runs a phrase spoken exactly. The
/// targets' German names are in Localizable.xcstrings.
struct OwnwaveShortcuts: AppShortcutsProvider {
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
    AppShortcut(
      intent: LikeIntent(),
      phrases: ["Like \(\.$target) in \(.applicationName)"],
      shortTitle: "Like",
      systemImageName: "heart")
    AppShortcut(
      intent: UnlikeIntent(),
      phrases: ["Unlike \(\.$target) in \(.applicationName)"],
      shortTitle: "Unlike",
      systemImageName: "heart.slash")
    AppShortcut(
      intent: BoostIntent(),
      phrases: ["Boost \(\.$target) in \(.applicationName)"],
      shortTitle: "Boost",
      systemImageName: "hand.thumbsup")
    AppShortcut(
      intent: AvoidIntent(),
      phrases: ["Avoid \(\.$target) in \(.applicationName)"],
      shortTitle: "Avoid",
      systemImageName: "hand.thumbsdown")
  }
}

extension Notification.Name {
  static let playRequested = Notification.Name("flo.playRequested")
}

/// What an intent asked the app to play. An app that registered a `handler`
/// (the iPhone) plays it while the intent waits. Otherwise the watch's root
/// view takes it; a
/// launch by the intent can run perform() before the view subscribed to the
/// notification, so the view also takes a pending request when it appears.
enum PlayRequest {
  case something
  case artist(id: String, name: String)

  /// Plays a request to the end, throwing what Siri should say when nothing
  /// plays. Set at launch by an app that plays without opening.
  @MainActor static var handler: (@MainActor (PlayRequest) async throws -> Void)?

  @MainActor private static var pending: PlayRequest?

  @MainActor static func run(_ request: PlayRequest) async throws {
    if let handler {
      try await handler(request)
    } else {
      post(request)
    }
  }

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

/// Why a play request played nothing, in the words Siri says.
struct PlayFailure: Error, CustomLocalizedStringResourceConvertible {
  let localizedStringResource: LocalizedStringResource

  static let signedOut = PlayFailure(
    localizedStringResource: "Sign in to Ownwave on your iPhone first.")
  static let nothingPlayed = PlayFailure(
    localizedStringResource: "Ownwave couldn't start playing.")
}
