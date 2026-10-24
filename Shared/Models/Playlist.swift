//
//  Playlist.swift
//  flo
//

import Foundation

struct Playlist: Codable, Identifiable, Hashable, Playable {
  let id: String
  let name: String
  let comment: String
  let ownerName: String
  let coverArtId: String?
  var songs: [Song] = []
  /// The server's counts, 0 when unknown.
  var songCount = 0
  var duration: Double = 0
  /// When it last changed, ISO 8601; empty when unknown.
  var updatedAt = ""
  var isPlaylist: Bool { true }
  /// The server's cover for it, a mosaic of its albums.
  var artId: String { coverArtId ?? (id.hasPrefix("pl-") ? id : "pl-\(id)") }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case comment
    case ownerName
    case coverArtId
    case songs
    case songCount
    case duration
    case updatedAt
  }

  init(
    id: String = "",
    name: String = "",
    comment: String = "",
    ownerName: String = "",
    coverArtId: String? = nil,
    songs: [Song] = []
  ) {
    self.id = id
    self.name = name
    self.comment = comment
    self.ownerName = ownerName
    self.coverArtId = coverArtId
    self.songs = songs
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.id = try container.decode(String.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.comment = try container.decode(String.self, forKey: .comment)
    self.ownerName = try container.decode(String.self, forKey: .ownerName)
    self.coverArtId = try container.decodeIfPresent(String.self, forKey: .coverArtId)
    self.songs = try container.decodeIfPresent([Song].self, forKey: .songs) ?? []
    self.songCount = try container.decodeIfPresent(Int.self, forKey: .songCount) ?? 0
    self.duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
  }
}
