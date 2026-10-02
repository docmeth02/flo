//
//  Song.swift
//  flo
//
//  Created by rizaldy on 09/06/24.
//

import Foundation

struct Song: Codable, Identifiable, Hashable {
  let id: String
  let title: String
  let artist: String
  let albumId: String
  let albumName: String
  let trackNumber: Int
  let discNumber: Int
  let bitRate: Int
  let sampleRate: Int
  let suffix: String
  let duration: Double
  let explicitStatus: ExplicitStatus

  var mediaFileId: String = ""
  var fileUrl: String = ""
  var starred: Bool = false

  // Server metadata for smart shuffle, absent from downloads and the queue.
  var genre: String?
  var genres: [String]?
  var year: Int?
  var playCount: Int?
  var playDate: String?
  var rating: Int?
  var ratedAt: String?
  var starredAt: String?
  var artistId: String?
  var albumArtistId: String?

  var isExplicit: Bool {
    explicitStatus.isExplicit
  }

  enum DecodeKeys: String, CodingKey {
    case id
    case title
    case artist
    case albumId
    case album
    case albumName
    case trackNumber
    case discNumber
    case bitRate
    case sampleRate
    case suffix
    case duration
    case mediaFileId
    case starred
    case explicitStatus
    case genre
    case genres
    case year
    case playCount
    case playDate
    case rating
    case ratedAt
    case starredAt
    case artistId
    case albumArtistId
  }

  enum EncodeKeys: String, CodingKey {
    case id
    case title
    case artist
    case albumId
    case albumName = "album"
    case trackNumber
    case discNumber
    case bitRate
    case sampleRate
    case suffix
    case duration
    case mediaFileId
    case starred
    case explicitStatus
    case genre
    case genres
    case year
    case playCount
    case playDate
    case rating
    case ratedAt
    case starredAt
    case artistId
    case albumArtistId
  }

  /// The shape of an entry in the server's `genres` list; only the name is kept.
  private struct GenreName: Codable {
    let name: String
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: DecodeKeys.self)

    self.id = try container.decode(String.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.artist = try container.decode(String.self, forKey: .artist)
    self.albumId = try container.decode(String.self, forKey: .albumId)
    self.albumName =
      try container.decodeIfPresent(String.self, forKey: .album)
      ?? container.decodeIfPresent(String.self, forKey: .albumName)
      ?? ""

    self.trackNumber = try container.decode(Int.self, forKey: .trackNumber)
    self.discNumber = try container.decode(Int.self, forKey: .discNumber)
    self.bitRate = try container.decode(Int.self, forKey: .bitRate)
    self.sampleRate = try container.decode(Int.self, forKey: .sampleRate)
    self.suffix = try container.decode(String.self, forKey: .suffix)
    self.duration = try container.decode(Double.self, forKey: .duration)
    self.mediaFileId = try container.decodeIfPresent(String.self, forKey: .mediaFileId) ?? ""
    self.starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
    self.explicitStatus = ExplicitStatus(
      from: try container.decodeIfPresent(String.self, forKey: .explicitStatus))
    // Metadata is optional: a field of an unexpected type must not fail the song.
    self.genre = try? container.decodeIfPresent(String.self, forKey: .genre)
    self.genres = (try? container.decodeIfPresent([GenreName].self, forKey: .genres))?.map(\.name)
    self.year = try? container.decodeIfPresent(Int.self, forKey: .year)
    self.playCount = try? container.decodeIfPresent(Int.self, forKey: .playCount)
    self.playDate = try? container.decodeIfPresent(String.self, forKey: .playDate)
    self.rating = try? container.decodeIfPresent(Int.self, forKey: .rating)
    self.ratedAt = try? container.decodeIfPresent(String.self, forKey: .ratedAt)
    self.starredAt = try? container.decodeIfPresent(String.self, forKey: .starredAt)
    self.artistId = try? container.decodeIfPresent(String.self, forKey: .artistId)
    self.albumArtistId = try? container.decodeIfPresent(String.self, forKey: .albumArtistId)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: EncodeKeys.self)

    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(artist, forKey: .artist)
    try container.encode(albumId, forKey: .albumId)
    try container.encode(albumName, forKey: .albumName)
    try container.encode(trackNumber, forKey: .trackNumber)
    try container.encode(discNumber, forKey: .discNumber)
    try container.encode(bitRate, forKey: .bitRate)
    try container.encode(sampleRate, forKey: .sampleRate)
    try container.encode(suffix, forKey: .suffix)
    try container.encode(duration, forKey: .duration)
    try container.encode(mediaFileId, forKey: .mediaFileId)
    try container.encode(starred, forKey: .starred)
    try container.encode(explicitStatus.rawValue, forKey: .explicitStatus)
    try container.encodeIfPresent(genre, forKey: .genre)
    try container.encodeIfPresent(genres?.map(GenreName.init), forKey: .genres)
    try container.encodeIfPresent(year, forKey: .year)
    try container.encodeIfPresent(playCount, forKey: .playCount)
    try container.encodeIfPresent(playDate, forKey: .playDate)
    try container.encodeIfPresent(rating, forKey: .rating)
    try container.encodeIfPresent(ratedAt, forKey: .ratedAt)
    try container.encodeIfPresent(starredAt, forKey: .starredAt)
    try container.encodeIfPresent(artistId, forKey: .artistId)
    try container.encodeIfPresent(albumArtistId, forKey: .albumArtistId)
  }

  init(
    id: String, title: String, albumId: String, albumName: String, artist: String,
    trackNumber: Int, discNumber: Int,
    bitRate: Int,
    sampleRate: Int,
    suffix: String, duration: Double, mediaFileId: String,
    explicitStatus: ExplicitStatus = .unknown
  ) {
    self.id = id
    self.title = title
    self.artist = artist
    self.albumId = albumId
    self.albumName = albumName
    self.trackNumber = Int(trackNumber)
    self.discNumber = Int(discNumber)
    self.bitRate = Int(bitRate)
    self.sampleRate = Int(sampleRate)
    self.suffix = suffix
    self.duration = duration
    self.mediaFileId = mediaFileId
    self.explicitStatus = explicitStatus
  }

  init(from cache: CacheEntity) {
    self.id = cache.mediaFileId ?? ""
    self.title = cache.title ?? "Unknown"
    self.artist = cache.artistName ?? "Unknown"
    self.albumId = cache.albumId ?? ""
    self.albumName = cache.albumName ?? ""
    self.trackNumber = 0
    self.discNumber = 0
    self.bitRate = Int(cache.bitRate)
    self.sampleRate = Int(cache.sampleRate)
    self.suffix = cache.suffix ?? ""
    self.duration = cache.duration
    self.mediaFileId = cache.mediaFileId ?? ""
    self.explicitStatus = ExplicitStatus(from: cache.explicitStatus)
  }

  init(from song: SongEntity) {
    self.id = song.id ?? ""
    self.title = song.title ?? "N/A"
    self.artist = song.artistName ?? "N/A"
    self.albumId = song.albumId ?? ""

    if let storedAlbumName = song.albumName, !storedAlbumName.isEmpty {
      self.albumName = storedAlbumName
    } else if let fileURL = song.fileURL {
      let parts = fileURL.split(separator: "/")

      if parts.count >= 3 {
        self.albumName = String(parts[2])
      } else {
        self.albumName = ""
      }
    } else {
      self.albumName = ""
    }

    self.trackNumber = Int(song.trackNumber)
    self.discNumber = Int(song.discNumber)
    self.bitRate = Int(song.bitRate)
    self.sampleRate = Int(song.sampleRate)
    self.suffix = song.suffix ?? "N/A"
    self.duration = song.duration
    self.fileUrl = song.fileURL ?? ""
    self.mediaFileId = song.mediaFileId ?? ""
    self.explicitStatus = ExplicitStatus(from: song.explicitStatus)
  }
}
