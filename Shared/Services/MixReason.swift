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
      case .song: return MixReason(.rated, "You rated this \(facts.rating)")
      case .album: return MixReason(.rated, "From \(facts.album), an album you rated \(facts.rating)")
      case .artist: return MixReason(.rated, "From an artist you rated \(facts.rating)")
      }
    }
    if facts.starred { return MixReason(.liked, "You liked this song") }
    if facts.likedAlbum { return MixReason(.liked, "From \(facts.album), an album you liked") }
    if facts.likedArtist { return MixReason(.liked, "From an artist you liked") }
    if facts.topArtist {
      return MixReason(.history, "\(facts.artist) is your most-played artist")
    }
    if facts.songPlays >= 3 { return MixReason(.history, "Played \(facts.songPlays) times in 60 days") }
    if facts.artistPlays >= 5 {
      return MixReason(.history, "You play \(facts.artist) often · \(facts.artistPlays) plays in 60 days")
    }
    // Keep Playing's seed is the last song heard through, its genres the session's.
    if facts.seedArtist { return MixReason(.history, "Same artist as a song you just heard") }
    if facts.anchored { return MixReason(.history, "Fits this listening session") }
    return MixReason(.history, "Fits what you play")
  }

  private init(_ kind: Kind, _ note: String) {
    self.kind = kind
    self.note = note
  }

  /// "3 days", "5 weeks", "4 months"; at least a day ago.
  private static func since(_ date: Date, _ now: Date) -> String {
    let days = Int(now.timeIntervalSince(date) / 86400)
    if days < 14 { return counted(days, "day") }
    if days < 63 { return counted(days / 7, "week") }
    return counted(days / 30, "month")
  }
}
