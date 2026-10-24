//
//  MixReason.swift
//  Ownwave
//

import Foundation

/// Why a song is in a smart mix, in words for the listener: the pill in Now
/// Playing, the line under an Up Next row and the Taste recipe's category.
struct MixReason: Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable, CaseIterable {
    case history, liked, rated, explore
  }

  let kind: Kind
  let note: String
  /// The note shortened for a row's meta line: "Rated 5", "Album liked".
  let label: String

  /// What the ranker knew of the pick. Plays are the mirrored ones of the
  /// last 60 days; the artist's are summed over its spellings.
  struct Facts {
    var explore = false
    var rating = 0
    var ratingSource = MixRanker.Rating.Source.song
    var starred = false
    var likedAlbum = false
    var likedArtist = false
    var seedArtist = false
    var anchored = false
    var songPlays = 0
    var artistPlays = 0
    var topArtist = false
    /// The server's count or the mirror's, whichever is higher.
    var lifetimePlays = 0
    var artist = ""
    var album = ""
    var lastHeard: Date?
    var now = Date()
  }

  /// The strongest reason the listener would recognise: an explore slot,
  /// then ratings, likes and plays.
  static func make(_ facts: Facts) -> MixReason {
    if facts.explore {
      if let heard = facts.lastHeard, facts.now.timeIntervalSince(heard) >= 86400 {
        return MixReason(.explore, "Explore pick · not heard in \(since(heard, facts.now))")
      }
      return MixReason(
        .explore,
        facts.lifetimePlays == 0 && facts.lastHeard == nil
          ? "Explore pick · new to you" : "Explore pick · rarely played")
    }
    if facts.rating >= 4 {
      switch facts.ratingSource {
      case .song: return MixReason(.rated, "You rated this \(facts.rating)", "Rated \(facts.rating)")
      case .album:
        return MixReason(
          .rated, "From \(facts.album), an album you rated \(facts.rating)",
          "Album rated \(facts.rating)")
      case .artist:
        return MixReason(
          .rated, "From an artist you rated \(facts.rating)", "Artist rated \(facts.rating)")
      }
    }
    if facts.starred { return MixReason(.liked, "You liked this song", "Liked") }
    if facts.likedAlbum {
      return MixReason(.liked, "From \(facts.album), an album you liked", "Album liked")
    }
    if facts.likedArtist { return MixReason(.liked, "From an artist you liked", "Artist liked") }
    if facts.topArtist {
      return MixReason(
        .history, "\(facts.artist) is your most-played artist", "Your most-played artist")
    }
    if facts.songPlays >= 3 {
      return MixReason(
        .history, "Played \(facts.songPlays) times in 60 days", "Played \(facts.songPlays)× lately")
    }
    if facts.artistPlays >= 5 {
      return MixReason(
        .history, "You play \(facts.artist) often · \(facts.artistPlays) plays in 60 days",
        "An artist you play often")
    }
    // Keep Playing's seed is the last song heard through, its genres the session's.
    if facts.seedArtist {
      return MixReason(.history, "Same artist as a song you just heard", "Same artist as before")
    }
    if facts.anchored { return MixReason(.history, "Fits this listening session") }
    return MixReason(.history, "Fits what you play")
  }

  private init(_ kind: Kind, _ note: String, _ label: String? = nil) {
    self.kind = kind
    self.note = note
    self.label = label ?? note
  }

  private enum CodingKeys: String, CodingKey {
    case kind, note, label
  }

  // Mixes saved before build 47 have no label; their note stands in.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(Kind.self, forKey: .kind)
    note = try container.decode(String.self, forKey: .note)
    label = try container.decodeIfPresent(String.self, forKey: .label) ?? note
  }

  /// "3 days", "5 weeks", "4 months"; at least a day ago.
  private static func since(_ date: Date, _ now: Date) -> String {
    let days = Int(now.timeIntervalSince(date) / 86400)
    if days < 14 { return counted(days, "day") }
    if days < 63 { return counted(days / 7, "week") }
    return counted(days / 30, "month")
  }
}
