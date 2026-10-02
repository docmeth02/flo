//
//  AlbumService.swift
//  flo
//
//  Created by rizaldy on 08/06/24.
//

import Alamofire
import Foundation

/// What the server's list of an entity looks like right now: how many items
/// and when the newest one changed. Equal stamps mean an unchanged list.
struct LibraryStamp: Codable, Equatable {
  let total: Int?  // nil when the server sent no X-Total-Count
  let newestUpdatedAt: String?
}

private struct UpdatedAtOnly: Decodable {
  let updatedAt: String?
}

/// A song plus the server's updatedAt, which Song itself neither keeps nor caches.
struct SongPageItem: Decodable {
  let song: Song
  let updatedAt: String?

  private enum Keys: String, CodingKey { case updatedAt }

  init(from decoder: any Decoder) throws {
    song = try Song(from: decoder)
    updatedAt = try decoder.container(keyedBy: Keys.self)
      .decodeIfPresent(String.self, forKey: .updatedAt)
  }
}

class AlbumService {
  static let shared = AlbumService()

  // Downloads live in one folder per collection (album or playlist) named by
  // its id, with files named by media file id, so equal titles or track
  // numbers can never overwrite each other. Covers are stored once per album
  // or playlist id. Older downloads keep the artist/album paths stored in
  // SongEntity.fileURL and stay playable.
  static func downloadPath(collectionId: String, mediaFileId: String, suffix: String) -> String {
    "Media/\(collectionId)/\(mediaFileId).\(suffix)"
  }

  static func coverPath(id: String) -> String {
    "Media/covers/\(id).png"
  }

  func buildRemoteStreamUrl(id: String) -> String {
    let maxBitrate = UserDefaultsManager.maxBitRate

    let format =
      maxBitrate == TranscodingSettings.sourceBitRate
      ? TranscodingSettings.sourceFormat : TranscodingSettings.targetFormat

    return
      "\(UserDefaultsManager.serverBaseURL)\(API.SubsonicEndpoint.stream)\(AuthService.shared.getCreds(key: "subsonicToken"))&id=\(id)&maxBitRate=\(maxBitrate)&format=\(format)"
  }

  /// The downloaded file for a media id, if one exists on disk. Main thread.
  func downloadedFileURL(mediaFileId id: String) -> URL? {
    guard
      let localStream = CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.mediaFileId, value: id
      ).first,
      let localPath = localStream.fileURL,
      !localPath.isEmpty,
      LocalFileManager.shared.fileExists(fileName: localPath)
    else { return nil }

    return LocalFileManager.shared.fileURL(for: localPath)
  }

  func getStreamUrl(id: String) -> String {
    if let fileUrl = downloadedFileURL(mediaFileId: id) {
      return fileUrl.absoluteString
    }

    if let cachedUrl = StreamCacheManager.shared.cachedFileURL(mediaFileId: id) {
      return cachedUrl.absoluteString
    }

    return buildRemoteStreamUrl(id: id)
  }

  func isStarred(songId: String, completion: @escaping (Bool) -> Void) {
    let params: [String: Any] = [
      "_start": 0, "_end": 1, "id": songId,
    ]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getSong, parameters: params) {
      (response: DataResponse<[Song], AFError>) in
      switch response.result {
      case .success(let songs):
        completion(songs.first?.starred ?? false)
      case .failure:
        completion(false)
      }
    }
  }

  func starSong(id: String, completion: @escaping (Bool) -> Void) {
    let url =
      "\(UserDefaultsManager.serverBaseURL)\(API.SubsonicEndpoint.star)\(AuthService.shared.getCreds(key: "subsonicToken"))&id=\(id)"

    APIManager.shared.session.request(url)
      .validate(statusCode: 200..<300)
      .response { response in
        completion(response.error == nil)
      }
  }

  func unstarSong(id: String, completion: @escaping (Bool) -> Void) {
    let url =
      "\(UserDefaultsManager.serverBaseURL)\(API.SubsonicEndpoint.unstar)\(AuthService.shared.getCreds(key: "subsonicToken"))&id=\(id)"

    APIManager.shared.session.request(url)
      .validate(statusCode: 200..<300)
      .response { response in
        completion(response.error == nil)
      }
  }

  func getStarredSongs(completion: @escaping (Result<[Song], Error>) -> Void) {
    APIManager.shared.SubsonicEndpointRequest(
      endpoint: API.SubsonicEndpoint.getStarred2, parameters: nil
    ) {
      (response: DataResponse<Starred2Response, AFError>) in
      switch response.result {
      case .success(let starred):
        completion(.success(starred.songs))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getSongFromAlbum(id: String, completion: @escaping (Result<[Song], Error>) -> Void) {
    // FIXME: get all songs for now
    let params: [String: Any] = [
      "_start": 0, "_end": 0, "_order": "ASC", "_sort": "album", "album_id": id,
    ]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getSong, parameters: params) {
      (response: DataResponse<[Song], AFError>) in
      switch response.result {
      case .success(let song):
        completion(.success(song))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getDownloadedAlbum(completion: @escaping (Result<[Album], Error>) -> Void) {
    completion(
      .success(
        CoreDataManager.shared.getRecordsByEntity(entity: PlaylistEntity.self).map(Album.init)))
  }

  func getAlbum(completion: @escaping (Result<[Album], Error>) -> Void) {
    // FIXME: now we fetch all albums. let's see if this will affect performance
    let params: [String: Any] = ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getAlbum, parameters: params) {
      (response: DataResponse<[Album], AFError>) in
      switch response.result {
      case .success(let albums):
        completion(.success(albums))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getArtists(completion: @escaping (Result<[Artist], Error>) -> Void) {
    let params: [String: Any] = ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getArtists, parameters: params) {
      (response: DataResponse<[Artist], AFError>) in
      switch response.result {
      case .success(let artists):
        completion(.success(artists))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getAlbumsByArtist(id: String, completion: @escaping (Result<[Album], Error>) -> Void) {
    // TODO: now we fetch all albums. let's see if this will affect performance
    let params: [String: Any] = [
      "_start": 0, "_end": 0, "_order": "ASC", "_sort": "max_year desc,date desc", "artist_id": id,
    ]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getAlbum, parameters: params) {
      (response: DataResponse<[Album], AFError>) in
      switch response.result {
      case .success(let albums):
        completion(.success(albums))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getPlaylists(completion: @escaping (Result<[Playlist], Error>) -> Void) {
    let params: [String: Any] = ["_start": 0, "_end": 0, "_order": "ASC", "_sort": "name"]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getPlaylists, parameters: params) {
      (response: DataResponse<[Playlist], AFError>) in
      switch response.result {
      case .success(let playlists):
        completion(.success(playlists))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  // FIXME: currently we can't stream from the local (offline) one :)
  func getSongsByPlaylist(id: String, completion: @escaping (Result<[Song], Error>) -> Void) {
    let params: [String: Any] = [
      "playlist_id": id, "_start": 0, "_end": 0, "_order": "ASC", "_sort": "id",
    ]

    let endpoint = "\(API.NDEndpoint.getPlaylists)/\(id)/tracks"

    APIManager.shared.NDEndpointRequest(
      endpoint: endpoint, parameters: params
    ) {
      (response: DataResponse<[Song], AFError>) in
      switch response.result {
      case .success(let songs):
        completion(.success(songs))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  /// The stamp of the server's `entity` list ("song", "album", ...), from a
  /// one item request.
  func getLibraryStamp(
    entity: String, completion: @escaping (Result<LibraryStamp, Error>) -> Void
  ) {
    let params: [String: Any] = ["_start": 0, "_end": 1, "_sort": "updated_at", "_order": "DESC"]

    APIManager.shared.NDEndpointRequest(endpoint: "/api/\(entity)", parameters: params) {
      (response: DataResponse<[UpdatedAtOnly], AFError>) in
      switch response.result {
      case .success(let items):
        let total = response.response?.value(forHTTPHeaderField: "X-Total-Count")
          .flatMap(Int.init)
        completion(.success(LibraryStamp(total: total, newestUpdatedAt: items.first?.updatedAt)))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  /// One page of the song library, most recently changed first.
  func getSongsPage(
    start: Int, end: Int, completion: @escaping (Result<[SongPageItem], Error>) -> Void
  ) {
    let params: [String: Any] = [
      "_start": start, "_end": end, "_sort": "updated_at", "_order": "DESC",
    ]

    APIManager.shared.NDEndpointRequest(endpoint: API.NDEndpoint.getSong, parameters: params) {
      (response: DataResponse<[SongPageItem], AFError>) in
      switch response.result {
      case .success(let items):
        completion(.success(items))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func getSongsByAlbumId(albumId: String, limit: Int = 0) -> [Song] {
    let sortByTrackNumber = NSSortDescriptor(key: "trackNumber", ascending: true)

    return CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: albumId,
      sortDescriptors: [sortByTrackNumber]
    ).map(Song.init)
  }

  func getPlaylistSongs(playlistId: String) -> [Song] {
    let sortByPosition = NSSortDescriptor(key: "position", ascending: true)
    let sortByTrackNumber = NSSortDescriptor(key: "trackNumber", ascending: true)

    return CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: playlistId,
      sortDescriptors: [sortByPosition, sortByTrackNumber]
    ).map(Song.init)
  }

  func isPlaylistDownload(id: String) -> Bool {
    let songs = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id, limit: 1)

    return songs.first?.id?.hasPrefix("pl:") ?? false
  }

  func updatePlaylistPositions(playlistId: String, songs: [Song]) {
    let existing = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: playlistId)

    guard !existing.isEmpty else { return }

    var changed = false

    for (index, song) in songs.enumerated() where song.id.hasPrefix("pl:") {
      guard let entity = existing.first(where: { $0.id == song.id }) else { continue }

      let position = Int32(index)
      if entity.position != position {
        entity.position = position
        changed = true
      }
    }

    if changed {
      CoreDataManager.shared.saveRecord()
    }
  }

  func getAlbumCover(
    artistName: String,
    albumName: String,
    albumId: String = "",
    trackId: String = "",
    contextName: String? = nil,
    albumCover: String = ""
  ) -> String {
    // If album already has a cover URL/path, use it
    if !albumCover.isEmpty {
      if albumCover.hasPrefix("/") {
        return albumCover
      } else if albumCover.hasPrefix("http") {
        return albumCover
      } else {
        // Could be a relative path, try to get full path
        if LocalFileManager.shared.fileExists(fileName: albumCover) {
          return LocalFileManager.shared.fileURL(for: albumCover)?.path ?? ""
        }
      }
    }

    let coverTarget = Self.coverPath(id: albumId)
    if !albumId.isEmpty, LocalFileManager.shared.fileExists(fileName: coverTarget) {
      return LocalFileManager.shared.fileURL(for: coverTarget)?.path ?? ""
    }

    let target = "Media/\(artistName)/\(albumName)/cover.png"
    let anotherTarget = "Media/Various Artists/\(albumName)/cover/\(trackId).png"
    let contextTarget =
      contextName.map { "Media/Various Artists/\($0)/cover/\(trackId).png" }

    if LocalFileManager.shared.fileExists(fileName: target) {
      return LocalFileManager.shared.fileURL(for: target)?.path ?? ""
    } else if let contextTarget, LocalFileManager.shared.fileExists(fileName: contextTarget) {
      return LocalFileManager.shared.fileURL(for: contextTarget)?.path ?? ""
    } else if LocalFileManager.shared.fileExists(fileName: anotherTarget) {
      return LocalFileManager.shared.fileURL(for: anotherTarget)?.path ?? ""
    } else if let cached = CoverArtCacheManager.shared.cachedFilePath(albumId: albumId) {
      return cached
    } else {
      return
        "\(UserDefaultsManager.serverBaseURL)\(API.SubsonicEndpoint.coverArt)\(AuthService.shared.getCreds(key: "subsonicToken"))&id=al-\(albumId)&size=\(API.coverArtSize)"
    }
  }

  func downloadAlbumCover(
    albumId: String,
    completion: @escaping (Result<URL?, Error>) -> Void
  ) {
    let params: [String: Any] = ["id": "al-\(albumId)", "size": API.coverArtSize]

    APIManager.shared.SubsonicEndpointDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params
    ) { result in
      switch result {
      case .success(let tempFile):
        guard let target = LocalFileManager.shared.fileURL(for: Self.coverPath(id: albumId)) else {
          completion(.success(nil))
          return
        }
        LocalFileManager.shared.moveFile(source: tempFile, target: target, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  /// Cover of a playlist track's album, stored once per album id.
  func downloadAlbumCoverForPlaylist(
    albumId: String,
    completion: @escaping (Result<URL?, Error>) -> Void
  ) {
    let params: [String: Any] = ["id": "al-\(albumId)", "size": API.coverArtSize]

    APIManager.shared.SubsonicEndpointDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params
    ) { result in
      switch result {
      case .success(let tempFile):
        guard let target = LocalFileManager.shared.fileURL(for: Self.coverPath(id: albumId)) else {
          completion(.success(nil))
          return
        }

        LocalFileManager.shared.moveFile(
          source: tempFile, target: target, forceOverride: false, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func downloadPlaylistCover(
    playlistId: String,
    coverArtId: String?,
    completion: @escaping (Result<URL?, Error>) -> Void
  ) {
    let artId = coverArtId ?? (playlistId.hasPrefix("pl-") ? playlistId : "pl-\(playlistId)")
    let params: [String: Any] = ["id": artId, "size": API.coverArtSize]

    APIManager.shared.SubsonicEndpointDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params
    ) { result in
      switch result {
      case .success(let tempFile):
        guard let target = LocalFileManager.shared.fileURL(for: Self.coverPath(id: playlistId))
        else {
          completion(.success(nil))
          return
        }

        LocalFileManager.shared.moveFile(source: tempFile, target: target, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func saveDownload(
    albumId: String, albumName: String?, song: Song, status: String, isFromPlaylist: Bool = false,
    playlistIndex: Int = -1
  ) {
    let songId = isFromPlaylist ? "pl:\(albumId):\(song.mediaFileId)" : song.id
    let position = isFromPlaylist ? Int32(playlistIndex) : Int32(-1)

    let checkExistingSong = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.id, value: songId, limit: 1)

    let fileURL = Self.downloadPath(
      collectionId: albumId, mediaFileId: isFromPlaylist ? song.mediaFileId : song.id,
      suffix: song.suffix)

    let resolvedAlbumName = !song.albumName.isEmpty ? song.albumName : (albumName ?? "")

    if let existingSong = checkExistingSong.first {
      existingSong.fileURL = fileURL
      existingSong.albumName = resolvedAlbumName
      existingSong.status = status
      existingSong.position = position
      existingSong.explicitStatus = song.explicitStatus.rawValue
    } else {
      let downloadedSong = SongEntity(context: CoreDataManager.shared.viewContext)

      downloadedSong.albumId = albumId
      downloadedSong.albumName = resolvedAlbumName
      downloadedSong.id = songId
      downloadedSong.title = song.title
      downloadedSong.artistName = song.artist
      downloadedSong.bitRate = Int64(song.bitRate)
      downloadedSong.sampleRate = Int32(song.sampleRate)
      downloadedSong.discNumber = Int16(song.discNumber)
      downloadedSong.trackNumber = Int16(song.trackNumber)
      downloadedSong.suffix = song.suffix
      downloadedSong.duration = song.duration
      downloadedSong.fileURL = fileURL
      downloadedSong.status = status
      downloadedSong.mediaFileId = isFromPlaylist ? song.mediaFileId : song.id
      downloadedSong.position = position
      downloadedSong.explicitStatus = song.explicitStatus.rawValue
    }

    CoreDataManager.shared.saveRecord()
  }

  /// The downloaded collection record for `id`, reused when it exists so a
  /// repeated download updates it instead of colliding with it.
  private func collectionEntity(id: String) -> PlaylistEntity {
    CoreDataManager.shared.getRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: id, limit: 1
    ).first ?? PlaylistEntity(context: CoreDataManager.shared.viewContext)
  }

  func saveAlbum(_ albumToDownload: Album) {
    let album = collectionEntity(id: albumToDownload.id)

    album.id = albumToDownload.id
    album.name = albumToDownload.name
    album.genre = albumToDownload.genre
    album.minYear = Int64(albumToDownload.minYear)
    album.artistName = albumToDownload.artist
    album.albumArtist = albumToDownload.albumArtist
    album.explicitStatus = albumToDownload.explicitStatus.rawValue

    CoreDataManager.shared.saveRecord()
  }

  func savePlaylist(_ playlistToDownload: Playlist) {
    let playlist = collectionEntity(id: playlistToDownload.id)

    playlist.id = playlistToDownload.id
    playlist.name = playlistToDownload.name
    playlist.genre = "\(playlistToDownload.comment) by \(playlistToDownload.ownerName)"

    playlist.albumArtist = "Various Artists"
    playlist.artistName = "Various Artists"

    CoreDataManager.shared.saveRecord()
  }

  /// Media ids of the collection's downloaded songs.
  func downloadedMediaFileIds(collectionId: String) -> Set<String> {
    Set(
      CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.albumId, value: collectionId
      ).compactMap(\.mediaFileId))
  }

  func checkIfAlbumDownloaded(albumID: String) -> Bool {
    let isPlaylistEntityExist = CoreDataManager.shared.getRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: albumID, limit: 1)

    if isPlaylistEntityExist.isEmpty {
      return false
    } else {
      return CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.albumId, value: albumID, limit: 1
      ).first != nil
    }
  }

  func downloadNew(
    collectionId: String, mediaFileId: String, suffix: String,
    progressUpdate: ((Double) -> Void)?,
    completion: @escaping (Result<URL?, Error>) -> Void
  ) -> DownloadRequest {
    let params: [String: Any] = ["id": mediaFileId, "format": "raw", "bitrate": 0]
    let path = Self.downloadPath(
      collectionId: collectionId, mediaFileId: mediaFileId, suffix: suffix)

    return APIManager.shared.SubsonicEndpointDownloadNew(
      endpoint: API.SubsonicEndpoint.download, parameters: params, progressUpdate: progressUpdate
    ) { result in
      switch result {
      case .success(let tempFile):
        guard let target = LocalFileManager.shared.fileURL(for: path) else {
          completion(.success(nil))
          return
        }

        LocalFileManager.shared.moveFile(source: tempFile, target: target, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  /// Deletes an old-layout artist/album or playlist-name folder only once it
  /// holds nothing but cover images: a same-named collection downloaded by an
  /// older build may still keep its songs there.
  private func removeLegacyDirectoryIfUnused(_ path: String) {
    guard let url = LocalFileManager.shared.fileURL(for: path),
      let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
    else { return }

    let onlyCovers = contents.allSatisfy { $0 == "cover.png" || $0 == "cover" || $0 == ".DS_Store" }
    if onlyCovers {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Removes a downloaded album or playlist: every song file at its stored
  /// path (older downloads used artist/album folders), the collection folder,
  /// the collection's cover and, once empty, its legacy folder, then its
  /// records. Records go even when a folder is already missing, so nothing is
  /// left dangling.
  func removeDownloadedCollection(
    id: String, legacyDirectory: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    let songs = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id)

    var paths = songs.compactMap(\.fileURL).filter { !$0.isEmpty }
    paths += ["Media/\(id)", Self.coverPath(id: id)]

    for path in paths {
      guard let url = LocalFileManager.shared.fileURL(for: path),
        FileManager.default.fileExists(atPath: url.path)
      else { continue }

      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        completion(.failure(error))
        return
      }
    }

    removeLegacyDirectoryIfUnused(legacyDirectory)

    CoreDataManager.shared.deleteRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: id)
    CoreDataManager.shared.deleteRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id)

    completion(.success(true))
  }
}
