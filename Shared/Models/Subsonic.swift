//
//  Subsonic.swift
//  flo
//

protocol SubsonicResponseData: Decodable {
  static var key: String { get }
}

struct BasicResponse: SubsonicResponseData {
  static var key = ""
}

/// The `error` object of a Subsonic response whose status is "failed".
struct SubsonicError: Codable, Error {
  let code: Int
  let message: String?
}

extension SubsonicError {
  /// The failure a response reports, nil for "ok". Subsonic answers
  /// failures with HTTP 200, so the body's status is the only sign.
  init?(status: String, error: SubsonicError?) {
    guard status != "ok" else { return nil }
    self = error ?? SubsonicError(code: 0, message: status)
  }
}

struct SubsonicResponse<T: SubsonicResponseData>: Decodable {
  let status: String
  let error: SubsonicError?
  /// OpenSubsonic servers name their version in every answer.
  let serverVersion: String?
  let data: T?

  enum CodingKeys: String, CodingKey {
    case status
    case error
    case serverVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    status = try container.decode(String.self, forKey: .status)
    error = try container.decodeIfPresent(SubsonicError.self, forKey: .error)
    serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)

    let rootContainer = try decoder.container(keyedBy: ExtraField.self)
    data = try rootContainer.decodeIfPresent(T.self, forKey: ExtraField(stringValue: T.key))
  }
}

extension SubsonicResponse {
  struct ExtraField: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init?(intValue: Int) {
      self.stringValue = "\(intValue)"
      self.intValue = intValue
    }
  }
}

/// A Subsonic answer, unwrapped from its `subsonic-response` envelope.
struct SubsonicEnvelope<T: SubsonicResponseData>: Decodable {
  let subsonicResponse: SubsonicResponse<T>

  enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }

  /// The failure the answer reports, nil for "ok". A failed answer carries
  /// no payload, which must not read as an empty one.
  var failure: SubsonicError? {
    SubsonicError(status: subsonicResponse.status, error: subsonicResponse.error)
  }

  var data: T? { subsonicResponse.data }

  /// The payload read through `value`, or the reported failure.
  func result<Value>(_ value: (T?) -> Value) -> Result<Value, Error> {
    if let failure { return .failure(failure) }
    return .success(value(data))
  }
}

/// The getStarred2 payload: the liked songs, albums and artists.
struct Starred2: SubsonicResponseData {
  static let key = "starred2"

  struct Item: Decodable {
    let id: String
  }

  let song: [SubsonicSong]?
  let album: [Item]?
  let artist: [Item]?

  var songs: [Song] {
    (song ?? []).map { $0.toSong() }
  }

  var collections: StarredCollections {
    StarredCollections(albums: (album ?? []).map(\.id), artists: (artist ?? []).map(\.id))
  }
}

/// The ids of the account's liked albums and artists.
struct StarredCollections: Codable {
  let albums: [String]
  let artists: [String]
}

struct SubsonicSong: Codable {
  let id: String
  let title: String
  let artist: String?
  let albumId: String?
  let album: String?
  let track: Int?
  let discNumber: Int?
  let bitRate: Int?
  let samplingRate: Int?
  let suffix: String?
  let duration: Int?
  let explicitStatus: String?
  let genre: String?
  let year: Int?
  let userRating: Int?
  let playCount: Int?
  let starred: String?

  func toSong() -> Song {
    var song = Song(
      id: id, title: title, albumId: albumId ?? "", albumName: album ?? "",
      artist: artist ?? "", trackNumber: track ?? 0, discNumber: discNumber ?? 0,
      bitRate: bitRate ?? 0, sampleRate: samplingRate ?? 0, suffix: suffix ?? "",
      duration: Double(duration ?? 0), mediaFileId: id,
      explicitStatus: ExplicitStatus(from: explicitStatus))
    song.genre = genre
    song.year = year
    song.rating = userRating
    song.playCount = playCount
    song.starredAt = starred
    return song
  }
}

/// The server's answer to "how should this watch play this song"
/// (OpenSubsonic `transcoding` extension).
struct TranscodeDecision: SubsonicResponseData {
  static var key = "transcodeDecision"

  struct StreamInfo: Codable {
    let container: String?
    let codec: String?
    let audioBitrate: Int?
  }

  let canDirectPlay: Bool?
  let canTranscode: Bool?
  /// Signed token for getTranscodeStream; the server rejects it once stale.
  let transcodeParams: String?
  let sourceStream: StreamInfo?
  let transcodeStream: StreamInfo?
  let errorReason: String?
}

/// What the watch can play, sent with every transcode decision request.
/// The server only transcodes to mp3: 0.64 drops AAC transcoding profiles.
struct TranscodeClientInfo: Encodable {
  struct DirectPlayProfile: Encodable {
    let containers: [String]
    let audioCodecs: [String]
    let protocols: [String]
  }

  struct TranscodingProfile: Encodable {
    let container: String
    let audioCodec: String
    let `protocol`: String
    let maxAudioChannels: Int
  }

  let name = AppMeta.name
  let platform = AppPlatform.name
  // Bits per second; left out when there is no limit.
  let maxAudioBitrate: Int?
  let maxTranscodingAudioBitrate: Int?
  let directPlayProfiles = [
    DirectPlayProfile(
      containers: ["mp3", "m4a", "mp4", "aac", "flac", "wav", "aif", "aiff"],
      audioCodecs: ["mp3", "aac", "alac", "flac", "pcm_s16le", "pcm_s24le"],
      protocols: ["http"])
  ]
  let transcodingProfiles = [
    TranscodingProfile(container: "mp3", audioCodec: "mp3", protocol: "http", maxAudioChannels: 2)
  ]
  let codecProfiles: [String] = []

  init(maxBitRateKbps kbps: Int) {
    maxAudioBitrate = kbps > 0 ? kbps * 1000 : nil
    maxTranscodingAudioBitrate = maxAudioBitrate
  }
}
