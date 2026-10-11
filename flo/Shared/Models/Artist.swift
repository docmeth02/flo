//
//  Artist.swift
//  flo
//
//  Created by rizaldy on 14/11/24.
//

import Foundation

struct Artist: Codable, Hashable, Identifiable {
  static func == (lhs: Artist, rhs: Artist) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  let id, name: String
  let albumCount: Int
  let mbzArtistID: String?
  var starred = false

  enum CodingKeys: String, CodingKey {
    case id, name, albumCount, starred
    case mbzArtistID = "mbzArtistId"
  }
}

extension Artist {
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.id = try container.decode(String.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.albumCount = try container.decodeIfPresent(Int.self, forKey: .albumCount) ?? 0
    self.mbzArtistID = try container.decodeIfPresent(String.self, forKey: .mbzArtistID)
    self.starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
  }
}
