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
  let orderArtistName: String
  let stats: ArtistStats?
  let size, albumCount, songCount: Int
  let missing: Bool
  let createdAt, updatedAt: String
  let sortArtistName: String?
  let playCount: Int?
  let playDate, mbzArtistID, biography: String?
  let smallImageURL, mediumImageURL, largeImageURL: String?
  let externalURL: String?
  let externalInfoUpdatedAt: String?
  let fullText: String?

  enum CodingKeys: String, CodingKey {
    case id, name, orderArtistName, stats, size, albumCount, songCount, missing, createdAt, updatedAt, sortArtistName, playCount, playDate, fullText
    case mbzArtistID = "mbzArtistId"
    case biography
    case smallImageURL = "smallImageUrl"
    case mediumImageURL = "mediumImageUrl"
    case largeImageURL = "largeImageUrl"
    case externalURL = "externalUrl"
    case externalInfoUpdatedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.id = try container.decode(String.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.orderArtistName = try container.decodeIfPresent(String.self, forKey: .orderArtistName) ?? ""
    self.stats = try container.decodeIfPresent(ArtistStats.self, forKey: .stats)
    self.size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    self.albumCount = try container.decodeIfPresent(Int.self, forKey: .albumCount) ?? 0
    self.songCount = try container.decodeIfPresent(Int.self, forKey: .songCount) ?? 0
    self.missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    self.createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    self.sortArtistName = try container.decodeIfPresent(String.self, forKey: .sortArtistName)
    self.playCount = try container.decodeIfPresent(Int.self, forKey: .playCount)
    self.playDate = try container.decodeIfPresent(String.self, forKey: .playDate)
    self.mbzArtistID = try container.decodeIfPresent(String.self, forKey: .mbzArtistID)
    self.biography = try container.decodeIfPresent(String.self, forKey: .biography)
    self.smallImageURL = try container.decodeIfPresent(String.self, forKey: .smallImageURL)
    self.mediumImageURL = try container.decodeIfPresent(String.self, forKey: .mediumImageURL)
    self.largeImageURL = try container.decodeIfPresent(String.self, forKey: .largeImageURL)
    self.externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL)
    self.externalInfoUpdatedAt = try container.decodeIfPresent(String.self, forKey: .externalInfoUpdatedAt)
    self.fullText = try container.decodeIfPresent(String.self, forKey: .fullText)
  }
}

// MARK: - Stats
struct ArtistStats: Codable {
  let producer, composer, artist, maincredit: Albumartist?
  let albumartist, arranger, engineer, performer: Albumartist?
  let mixer, lyricist, conductor: Albumartist?
}

// MARK: - Albumartist
struct Albumartist: Codable {
  let songCount, albumCount, size: Int
}
