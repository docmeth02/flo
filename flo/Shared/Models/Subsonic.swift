//
//  Subsonic.swift
//  flo
//
//  Created by rizaldy on 11/01/25.
//

protocol SubsonicResponseData: Codable {
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

struct SubsonicResponse<T: SubsonicResponseData>: Codable {
  let status: String
  let version: String
  let type: String
  let serverVersion: String
  let openSubsonic: Bool
  let error: SubsonicError?
  let data: T?

  enum CodingKeys: String, CodingKey {
    case status
    case version
    case type
    case serverVersion
    case openSubsonic
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    status = try container.decode(String.self, forKey: .status)
    version = try container.decode(String.self, forKey: .version)
    type = try container.decode(String.self, forKey: .type)
    serverVersion = try container.decode(String.self, forKey: .serverVersion)
    openSubsonic = try container.decode(Bool.self, forKey: .openSubsonic)
    error = try container.decodeIfPresent(SubsonicError.self, forKey: .error)

    let rootContainer = try decoder.container(keyedBy: ExtraField.self)
    data = try rootContainer.decodeIfPresent(T.self, forKey: ExtraField(stringValue: T.key))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(status, forKey: .status)
    try container.encode(version, forKey: .version)
    try container.encode(type, forKey: .type)
    try container.encode(serverVersion, forKey: .serverVersion)
    try container.encode(openSubsonic, forKey: .openSubsonic)
    try container.encodeIfPresent(error, forKey: .error)

    if let data = data, let dynamicKey = CodingKeys(rawValue: T.key) {
      try container.encode(data, forKey: dynamicKey)
    }
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

/// A Subsonic response without payload, unwrapped from its
/// `subsonic-response` envelope.
struct BasicSubsonicResponse: Codable {
  let subsonicResponse: SubsonicResponse<BasicResponse>

  enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }
}

struct Starred2Response: Codable {
  struct SubsonicResponseBody: Codable {
    struct Starred2: Codable {
      let song: [SubsonicSong]?
    }

    let starred2: Starred2?
  }

  let subsonicResponse: SubsonicResponseBody

  enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }

  var songs: [Song] {
    return (subsonicResponse.starred2?.song ?? []).map { $0.toSong() }
  }
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

  func toSong() -> Song {
    return Song(
      id: id, title: title, albumId: albumId ?? "", albumName: album ?? "",
      artist: artist ?? "", trackNumber: track ?? 0, discNumber: discNumber ?? 0,
      bitRate: bitRate ?? 0, sampleRate: samplingRate ?? 0, suffix: suffix ?? "",
      duration: Double(duration ?? 0), mediaFileId: id,
      explicitStatus: ExplicitStatus(from: explicitStatus))
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

struct TranscodeDecisionResponse: Codable {
  let subsonicResponse: SubsonicResponse<TranscodeDecision>

  enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }
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
  let platform = "watchOS"
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
