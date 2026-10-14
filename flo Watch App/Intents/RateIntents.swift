//
//  RateIntents.swift
//  flo Watch App
//

import AppIntents

// Siri commands about what is playing: like or unlike it, boost or avoid it
// in smart shuffle. Saying one twice changes nothing. Each case names a whole
// noun phrase, so the German phrases get the article right.

enum LikeTarget: String, AppEnum {
  case song, album, artist

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
  static var caseDisplayRepresentations: [LikeTarget: DisplayRepresentation] = [
    .song: DisplayRepresentation(title: "this song", synonyms: ["this track", "this tune"]),
    .album: DisplayRepresentation(title: "this album"),
    .artist: DisplayRepresentation(title: "this artist", synonyms: ["this band", "this musician"]),
  ]
}

/// Smart shuffle takes ratings for songs and artists.
enum RateTarget: String, AppEnum {
  case song, artist

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
  static var caseDisplayRepresentations: [RateTarget: DisplayRepresentation] = [
    .song: DisplayRepresentation(title: "this song", synonyms: ["this track", "this tune"]),
    .artist: DisplayRepresentation(title: "this artist", synonyms: ["this band", "this musician"]),
  ]
}

struct LikeIntent: AppIntent {
  static var title: LocalizedStringResource = "Like"
  static var description = IntentDescription("Likes the song, album or artist playing.")
  static var openAppWhenRun = false

  @Parameter(title: "Item")
  var target: LikeTarget

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await reply()))
  }

  @MainActor func reply() async -> String { await NowPlayingEdit.star(true, target) }
}

struct UnlikeIntent: AppIntent {
  static var title: LocalizedStringResource = "Unlike"
  static var description = IntentDescription("Removes the song, album or artist playing from your likes.")
  static var openAppWhenRun = false

  @Parameter(title: "Item")
  var target: LikeTarget

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await reply()))
  }

  @MainActor func reply() async -> String { await NowPlayingEdit.star(false, target) }
}

struct BoostIntent: AppIntent {
  static var title: LocalizedStringResource = "Boost"
  static var description = IntentDescription("Rates the song or artist playing 5 for smart shuffle.")
  static var openAppWhenRun = false

  @Parameter(title: "Item")
  var target: RateTarget

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await reply()))
  }

  @MainActor func reply() async -> String { await NowPlayingEdit.rate(5, target) }
}

struct AvoidIntent: AppIntent {
  static var title: LocalizedStringResource = "Avoid"
  static var description = IntentDescription("Rates the song or artist playing 1 for smart shuffle.")
  static var openAppWhenRun = false

  @Parameter(title: "Item")
  var target: RateTarget

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await reply()))
  }

  @MainActor func reply() async -> String { await NowPlayingEdit.rate(1, target) }
}

/// The edits behind the intents and the sentences Siri answers with.
@MainActor private enum NowPlayingEdit {
  struct Refusal: Error {
    let sentence: LocalizedStringResource
  }

  static func star(_ starred: Bool, _ item: LikeTarget) async -> String {
    do {
      let (id, name, artist) = try playing(item)
      if item == .song {
        StarStore.shared.setSong(starred, id: id)
      } else {
        StarStore.shared.set(starred, id: id)
      }
      let sentence: LocalizedStringResource =
        if !starred { "Removed \(name) from your likes." }
        else if item == .song { "Liked \(name) by \(artist)." }
        else { "Liked \(name)." }
      return await answer(sentence) { StarStore.shared.isPending(id) }
    } catch {
      return String(localized: error.sentence)
    }
  }

  static func rate(_ rating: Int, _ item: RateTarget) async -> String {
    do {
      let (id, name, _) = try playing(item == .song ? .song : .artist)
      if item == .song {
        RatingStore.shared.set(rating, playbackID: id)
      } else {
        RatingStore.shared.setArtist(rating, artistId: id)
      }
      let sentence: LocalizedStringResource = rating >= 4 ? "Boosted \(name)." : "Avoiding \(name)."
      return await answer(sentence) { RatingStore.shared.isPending(id) }
    } catch {
      return String(localized: error.sentence)
    }
  }

  /// The id and name of the item playing, with the song's artist. Read
  /// before anything waits, so the edit cannot move to the next song.
  private static func playing(_ item: LikeTarget) throws(Refusal)
    -> (id: String, name: String, artist: String)
  {
    guard let target = NowPlayingTarget.current else {
      throw Refusal(sentence: "Nothing is playing in flo watch.")
    }
    guard !target.isLiveRadio else {
      throw Refusal(sentence: "A radio station can't be liked or rated.")
    }
    switch item {
    case .song: return (target.playbackID, target.title, target.artistName)
    case .album: return (target.albumId, target.albumName, target.artistName)
    case .artist:
      guard let artistId = target.artistId else {
        throw Refusal(sentence: "I don't know this artist yet.")
      }
      return (artistId, target.artistName, target.artistName)
    }
  }

  /// The sentence, and a note when the server has not taken the edit: it is
  /// sent at once while the server answers and gets two seconds to confirm.
  private static func answer(_ sentence: LocalizedStringResource, isPending: () -> Bool) async
    -> String
  {
    if ConnectivityMonitor.shared.canReachServer {
      for _ in 0..<8 where isPending() { try? await Task.sleep(for: .milliseconds(250)) }
    }
    let text = String(localized: sentence)
    guard isPending() else { return text }
    return text + " " + String(localized: "It syncs when your server is reachable.")
  }
}
