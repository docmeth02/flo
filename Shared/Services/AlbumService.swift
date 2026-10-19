//
//  AlbumService.swift
//  flo
//

import Alamofire
import Foundation

private struct UpdatedAtOnly: Decodable {
  let updatedAt: String?
}

class AlbumService {
  static let shared = AlbumService()

  /// Whether the server has the song starred; nil when it could not tell.
  func isStarred(songId: String) async -> Bool? {
    let params: [String: Any] = [
      "_start": 0, "_end": 1, "id": songId,
    ]

    let response: DataResponse<[Song], AFError> =
      await APIManager.shared.ndRequest(endpoint: API.NDEndpoint.getSong, parameters: params)
    return response.value.map { $0.first?.starred ?? false }
  }

  /// Stars a song, album or artist; Navidrome takes all three as `id`.
  func star(id: String) async throws {
    try await APIManager.shared.subsonicAction(
      endpoint: API.SubsonicEndpoint.star, parameters: ["id": id])
  }

  func unstar(id: String) async throws {
    try await APIManager.shared.subsonicAction(
      endpoint: API.SubsonicEndpoint.unstar, parameters: ["id": id])
  }

  /// Rates a song, album or artist 1 to 5; 0 removes its rating. Navidrome
  /// takes all three as `id`.
  func setRating(id: String, rating: Int) async throws {
    try await APIManager.shared.subsonicAction(
      endpoint: API.SubsonicEndpoint.setRating, parameters: ["id": id, "rating": rating])
  }

  /// Every song the account rated, with its rating.
  func getRatedSongs() async throws -> [Song] {
    try await ndList(API.NDEndpoint.getSong, ["has_rating": "true", "_start": 0, "_end": 0])
  }

  /// Every album the account rated, with its rating.
  func getRatedAlbums() async throws -> [Album] {
    try await ndList(API.NDEndpoint.getAlbum, ["has_rating": "true", "_start": 0, "_end": 0])
  }

  /// Every artist the account rated, with its rating.
  func getRatedArtists() async throws -> [Artist] {
    try await ndList(API.NDEndpoint.getArtists, ["has_rating": "true", "_start": 0, "_end": 0])
  }

  /// The server's version, nil when it does not say or does not answer.
  func serverVersion() async -> String? {
    let response: DataResponse<SubsonicEnvelope<BasicResponse>, AFError> =
      await APIManager.shared.subsonicRequest(endpoint: API.SubsonicEndpoint.ping, parameters: nil)
    return response.value?.subsonicResponse.serverVersion
  }

  /// Every liked song, album and artist of the account.
  func getStarred() async throws -> (songs: [Song], collections: StarredCollections) {
    let response: DataResponse<SubsonicEnvelope<Starred2>, AFError> =
      await APIManager.shared.subsonicRequest(
        endpoint: API.SubsonicEndpoint.getStarred2, parameters: nil)
    let starred = try response.result.get()
      .payload { $0 ?? Starred2(song: nil, album: nil, artist: nil) }
    return (starred.songs, starred.collections)
  }

  func getSongFromAlbum(id: String) async throws -> [Song] {
    try await ndList(
      API.NDEndpoint.getSong,
      ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "album", "album_id": id])
  }

  func getAlbum() async throws -> [Album] {
    try await ndList(
      API.NDEndpoint.getAlbum, ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"])
  }

  func getArtists() async throws -> [Artist] {
    try await ndList(
      API.NDEndpoint.getArtists, ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"])
  }

  func getAlbumsByArtist(id: String) async throws -> [Album] {
    try await ndList(
      API.NDEndpoint.getAlbum,
      [
        "_start": 0, "_end": 0, "_order": "ASC", "_sort": "max_year desc,date desc",
        "artist_id": id,
      ])
  }

  func getPlaylists() async throws -> [Playlist] {
    try await ndList(
      API.NDEndpoint.getPlaylists, ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"])
  }

  func getSongsByPlaylist(id: String) async throws -> [Song] {
    try await ndList(
      "\(API.NDEndpoint.getPlaylists)/\(id)/tracks",
      ["playlist_id": id, "_start": 0, "_end": 0, "_order": "ASC", "_sort": "id"])
  }

  /// A whole list from Navidrome's own API.
  private func ndList<T: Decodable>(
    _ endpoint: String, _ parameters: [String: Any]
  ) async throws -> [T] {
    let response: DataResponse<[T], AFError> =
      await APIManager.shared.ndRequest(endpoint: endpoint, parameters: parameters)
    return try response.result.get()
  }

  /// The stamp of the server's `entity` list ("song", "album", ...), from a
  /// one item request.
  func getLibraryStamp(entity: String) async throws -> LibraryStamp {
    let params: [String: Any] = ["_start": 0, "_end": 1, "_sort": "updated_at", "_order": "DESC"]

    let response: DataResponse<[UpdatedAtOnly], AFError> =
      await APIManager.shared.ndRequest(endpoint: "/api/\(entity)", parameters: params)
    let items = try response.result.get()
    let total = response.response?.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init)
    return LibraryStamp(total: total, newestUpdatedAt: items.first?.updatedAt)
  }

  /// One page of the song library, most recently changed first.
  func getSongsPage(start: Int, end: Int) async throws -> [SongPageItem] {
    let params: [String: Any] = [
      "_start": start, "_end": end, "_sort": "updated_at", "_order": "DESC",
    ]

    return try await ndList(API.NDEndpoint.getSong, params)
  }

  /// One page of the server's play log, highest id first, with the log's size.
  func getScrobblePage(start: Int, end: Int) async throws -> (rows: [ScrobbleRow], total: Int?) {
    let params: [String: Any] = ["_start": start, "_end": end, "_sort": "id", "_order": "DESC"]

    let response: DataResponse<[ScrobbleRow], AFError> =
      await APIManager.shared.ndRequest(endpoint: API.NDEndpoint.getScrobbles, parameters: params)
    let rows = try response.result.get()
    let total = response.response?.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init)
    return (rows, total)
  }

  /// Downloads the cover art `artId` as the stored cover of `id`; without
  /// `overwrite` a cover already stored stays.
  @discardableResult
  func downloadCover(artId: String, as id: String, overwrite: Bool = true) async throws -> URL {
    let params: [String: Any] = ["id": artId, "size": AppPlatform.coverArtSize]

    let tempFile = try await APIManager.shared.subsonicDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params)
    return try LocalFileManager.shared.moveFile(
      source: tempFile,
      target: LocalFileManager.shared.fileURL(for: DownloadStore.coverPath(id: id)),
      forceOverride: overwrite)
  }

  /// The download of one song for `DownloadSession`: the original file for
  /// `kbps` 0, else an MP3 the server converts, which has no length.
  func downloadRequest(mediaFileId: String, kbps: Int) -> URLRequest? {
    guard !UserDefaultsManager.serverBaseURL.isEmpty else { return nil }
    let format = TranscodingSettings.convertedFormat(kbps: kbps) ?? TranscodingSettings.sourceFormat
    let params: [String: Any] = ["id": mediaFileId, "format": format, "bitrate": kbps]
    return URL(string: subsonicURL(endpoint: API.SubsonicEndpoint.download, parameters: params))
      .map { URLRequest(url: $0) }
  }
}
