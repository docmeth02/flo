//
//  Playlist.swift
//  flo
//
//  Created by rizaldy on 15/11/24.
//

import Foundation

struct Playlist: Codable, Identifiable, Hashable, Playable {
  let id: String
  let name: String
  let comment: String
  let ownerName: String
  let coverArtId: String?
  var songs: [Song] = []

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case comment
    case ownerName
    case coverArtId
    case songs
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
  }
}
