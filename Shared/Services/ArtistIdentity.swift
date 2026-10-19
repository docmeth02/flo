//
//  ArtistIdentity.swift
//  flo
//

import Foundation

/// One artist for recommendations, however its tags spell it.
enum ArtistIdentity {
  private static let locale = Locale(identifier: "en_US_POSIX")

  /// "mbz:<id>" with a MusicBrainz id, else "name:<folded name>"; nil when
  /// neither gives anything to compare (the caller falls back to the server id).
  static func key(name: String?, mbid: String?) -> String? {
    if let mbid = normalized(mbid) { return "mbz:" + mbid }
    guard let name else { return nil }
    // Case, accents and width fold away, then everything but letters and
    // digits: "Baby Metal", "BABYMETAL" and "ＢＡＢＹＭＥＴＡＬ" are one name.
    let folded = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    let kept = String(
      String.UnicodeScalarView(
        folded.unicodeScalars.filter {
          CharacterSet.alphanumerics.contains($0)
        }))
    return kept.isEmpty ? nil : "name:" + kept
  }

  /// The key of each listed artist by server id. An artist listed without a
  /// MusicBrainz id takes the one its other spellings carry, unless they
  /// carry several.
  static func keys(of artists: [Artist]) -> [String: String] {
    var mbidsByName: [String: Set<String>] = [:]
    for artist in artists {
      guard let mbid = normalized(artist.mbzArtistID),
        let name = key(name: artist.name, mbid: nil)
      else { continue }
      mbidsByName[name, default: []].insert(mbid)
    }
    return artists.reduce(into: [:]) { keys, artist in
      // A name shared by different MusicBrainz artists borrows none of them.
      let borrowed = key(name: artist.name, mbid: nil).flatMap { name in
        mbidsByName[name].flatMap { $0.count == 1 ? $0.first : nil }
      }
      keys[artist.id] = key(name: artist.name, mbid: normalized(artist.mbzArtistID) ?? borrowed)
    }
  }

  private static func normalized(_ mbid: String?) -> String? {
    guard let mbid = mbid?.trimmingCharacters(in: .whitespaces).lowercased(), !mbid.isEmpty
    else { return nil }
    return mbid
  }
}
