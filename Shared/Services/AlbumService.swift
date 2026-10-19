//
//  AlbumService.swift
//  flo
//

import Alamofire
import Foundation

private struct UpdatedAtOnly: Decodable {
  let updatedAt: String?
}

/// Where a remote song streams from: a server-decided direct play or
/// transcode (getTranscodeStream).
struct StreamSource {
  let endpoint: String
  let parameters: [String: Any]
  let suffix: String
  /// A decided transcode, which starts at the requested offset. A direct play
  /// starts at 0 and is seeked by the client.
  let isTranscoded: Bool

  var url: String { subsonicURL(endpoint: endpoint, parameters: parameters) }
}

/// Why no stream could be set up for a song.
enum StreamSourceFailure: Error, Equatable {
  /// The network or the server is away for now; the song itself may be fine.
  case unavailable
  /// The server says this song cannot be streamed.
  case unplayable
  /// Streaming is switched off on this network.
  case blocked
}

/// How a failed transcode decision request is handled.
enum DecisionFailure: Error, Equatable {
  /// A hiccup on the way to the server: asked once more, then `.unavailable`.
  case transient
  case unavailable
  case unplayable

  /// Sorts a failed request by its HTTP status (nil without an answer), the
  /// URL loading error and whether the body carried a Subsonic error.
  static func classify(status: Int?, error: Error?, subsonicError: Bool) -> DecisionFailure {
    if subsonicError { return .unplayable }
    if let status {
      return [408, 429, 500, 502, 503, 504].contains(status) ? .transient : .unavailable
    }
    return ConnectivityMonitor.isConnectionError(error) ? .transient : .unavailable
  }

  var streamFailure: StreamSourceFailure { self == .unplayable ? .unplayable : .unavailable }
}

class AlbumService {
  static let shared = AlbumService()

  // Usable transcode decisions per song and bitrate setting. The Task is
  // cached so the player, the prefetch and the pre-cache share one request
  // and its retry. Main actor only.
  private var transcodeDecisions:
    [String: (task: Task<Result<TranscodeDecision, DecisionFailure>, Never>, at: Date)] = [:]
  // The token is signed for 48 hours.
  private static let decisionLifetime: TimeInterval = 24 * 3600

  private init() {
    NotificationCenter.default.addObserver(
      forName: .didLogout, object: nil, queue: .main
    ) { [weak self] _ in
      // A pending request must not retry for the next account.
      self?.transcodeDecisions.values.forEach { $0.task.cancel() }
      self?.transcodeDecisions = [:]
    }
  }

  // Downloads live in one folder per collection (album or playlist) named by
  // its id, with files named by media file id, so equal titles or track
  // numbers can never overwrite each other. Covers are stored once per album
  // or playlist id.
  static func downloadPath(collectionId: String, mediaFileId: String, suffix: String) -> String {
    "Media/\(collectionId)/\(mediaFileId).\(suffix)"
  }

  static func coverPath(id: String) -> String {
    "Media/covers/\(id).png"
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

  /// A downloaded or stream-cached copy of the song, if one exists. Main thread.
  func localFileURL(mediaFileId id: String) -> URL? {
    downloadedFileURL(mediaFileId: id) ?? StreamCacheManager.shared.cachedFileURL(mediaFileId: id)
  }

  /// How to stream a song from the server, as the server decides it.
  /// `offset` (seconds) only applies to a transcode.
  @MainActor func resolveStreamSource(songId: String, originalSuffix: String?, offset: Int) async
    -> Result<StreamSource, StreamSourceFailure>
  {
    guard let bitRate = TranscodingSettings.streamingBitRate else { return .failure(.blocked) }
    let kbps = Int(bitRate) ?? 0
    // Asked even while the monitor says the server is away: its verdict can
    // be stale, and the request is bounded.
    switch await transcodeDecision(songId: songId, kbps: kbps) {
    case .failure(let failure):
      return .failure(failure.streamFailure)
    case .success(let decision):
      guard
        let source = Self.streamSource(
          decision, songId: songId, originalSuffix: originalSuffix, offset: offset)
      else { return .failure(.unplayable) }
      return .success(source)
    }
  }

  /// Asks for the next song's decision ahead of time. Main thread.
  func prefetchTranscodeDecision(songId: String) {
    guard ConnectivityMonitor.shared.isServerReachable, localFileURL(mediaFileId: songId) == nil,
      let bitRate = TranscodingSettings.streamingBitRate
    else { return }
    let kbps = Int(bitRate) ?? 0
    Task { @MainActor in _ = await transcodeDecision(songId: songId, kbps: kbps) }
  }

  /// Drops a song's decision, whose token the server may no longer accept.
  /// Main thread.
  func forgetTranscodeDecision(songId: String) {
    transcodeDecisions = transcodeDecisions.filter { !$0.key.hasPrefix("\(songId)_") }
  }

  private static func rawSuffix(_ originalSuffix: String?) -> String {
    guard let originalSuffix, !originalSuffix.isEmpty else {
      return TranscodingSettings.sourceFormat
    }
    return originalSuffix
  }

  /// The stream a decision allows, the original file first; nil when it
  /// allows none.
  private static func streamSource(
    _ decision: TranscodeDecision, songId: String, originalSuffix: String?, offset: Int
  ) -> StreamSource? {
    guard let token = decision.transcodeParams, !token.isEmpty else { return nil }
    // Never estimateContentLength: the estimate ignores the offset.
    var parameters: [String: Any] = [
      "mediaId": songId, "mediaType": "song", "transcodeParams": token,
    ]
    if decision.canDirectPlay == true {
      return StreamSource(
        endpoint: API.SubsonicEndpoint.getTranscodeStream, parameters: parameters,
        suffix: decision.sourceStream?.container ?? rawSuffix(originalSuffix),
        isTranscoded: false)
    }
    guard decision.canTranscode == true, let stream = decision.transcodeStream else { return nil }
    if offset > 0 { parameters["offset"] = offset }
    return StreamSource(
      endpoint: API.SubsonicEndpoint.getTranscodeStream, parameters: parameters,
      suffix: stream.container ?? TranscodingSettings.targetFormat, isTranscoded: true)
  }

  @MainActor private func transcodeDecision(songId: String, kbps: Int) async
    -> Result<TranscodeDecision, DecisionFailure>
  {
    guard !songId.isEmpty else { return .failure(.unplayable) }
    let key = "\(songId)_\(kbps)"

    if let cached = transcodeDecisions[key],
      Date().timeIntervalSince(cached.at) < Self.decisionLifetime
    {
      return await cached.task.value
    }

    let task = Task { () -> Result<TranscodeDecision, DecisionFailure> in
      let first = await self.fetchTranscodeDecision(songId: songId, kbps: kbps)
      guard case .failure(.transient) = first else { return first }
      // Once more after a short pause, unless a logout cancelled the task.
      guard (try? await Task.sleep(for: .seconds(1))) != nil else { return first }
      RequestLog.shared.note("transcode decision retry \(songId)")
      return await self.fetchTranscodeDecision(songId: songId, kbps: kbps)
    }
    transcodeDecisions[key] = (task, Date())
    let result = await task.value
    // A failed request is asked again next time.
    if case .failure = result, transcodeDecisions[key]?.task == task {
      transcodeDecisions[key] = nil
    }
    return result
  }

  /// One decision request of at most 10 s. A decision that allows no stream
  /// counts as `.unplayable`.
  @MainActor private func fetchTranscodeDecision(songId: String, kbps: Int) async
    -> Result<TranscodeDecision, DecisionFailure>
  {
    let url = subsonicURL(
      endpoint: API.SubsonicEndpoint.getTranscodeDecision,
      parameters: ["mediaId": songId, "mediaType": "song"])

    let response = await APIManager.shared.session.request(
      url, method: .post, parameters: TranscodeClientInfo(maxBitRateKbps: kbps),
      encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = 10 }
    )
    .validate(statusCode: 200..<300)
    .serializingDecodable(SubsonicEnvelope<TranscodeDecision>.self).response

    let underlyingError = response.error?.underlyingError
    ConnectivityMonitor.shared.record(response: response.response, error: underlyingError)

    let subsonicError = response.value?.subsonicResponse.error
    if let error = subsonicError {
      // A failed decision (ffprobe on a damaged file, a database hiccup)
      // concerns this song only.
      debugLog("transcode decision for \(songId) failed: \(error.code) \(error.message ?? "")")
    }
    guard let decision = response.value?.subsonicResponse.data, subsonicError == nil else {
      return .failure(
        DecisionFailure.classify(
          status: response.response?.statusCode, error: underlyingError,
          subsonicError: subsonicError != nil))
    }
    guard
      Self.streamSource(decision, songId: songId, originalSuffix: nil, offset: 0) != nil
    else {
      debugLog("transcode decision for \(songId) allows no stream: \(decision.errorReason ?? "")")
      return .failure(.unplayable)
    }
    return .success(decision)
  }

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

  /// The downloaded albums and playlists, each as an album.
  func downloadedAlbums() -> [Album] {
    CoreDataManager.shared.getRecordsByEntity(entity: PlaylistEntity.self).map { entity in
      var album = Album(from: entity)
      album.isPlaylist = isPlaylistDownload(id: album.id)
      return album
    }
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

  func getSongsByAlbumId(albumId: String) -> [Song] {
    let sortByDiscNumber = NSSortDescriptor(key: "discNumber", ascending: true)
    let sortByTrackNumber = NSSortDescriptor(key: "trackNumber", ascending: true)

    return CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: albumId,
      sortDescriptors: [sortByDiscNumber, sortByTrackNumber]
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

  /// The album's downloaded cover, if one is on disk.
  func downloadedCoverPath(albumId: String) -> String? {
    guard !albumId.isEmpty else { return nil }
    let path = LocalFileManager.shared.fileURL(for: Self.coverPath(id: albumId)).path
    return FileManager.default.fileExists(atPath: path) ? path : nil
  }

  /// The album's cover: its download, else the cover cache, else the server.
  func coverURL(albumId: String) -> String {
    downloadedCoverPath(albumId: albumId)
      ?? CoverArtCacheManager.shared.cachedFilePath(albumId: albumId)
      ?? subsonicURL(
        endpoint: API.SubsonicEndpoint.coverArt,
        parameters: ["id": "al-\(albumId)", "size": AppPlatform.coverArtSize])
  }

  /// Downloads the cover art `artId` as the stored cover of `id`; without
  /// `overwrite` a cover already stored stays.
  @discardableResult
  func downloadCover(artId: String, as id: String, overwrite: Bool = true) async throws -> URL {
    let params: [String: Any] = ["id": artId, "size": AppPlatform.coverArtSize]

    let tempFile = try await APIManager.shared.subsonicDownload(
      endpoint: API.SubsonicEndpoint.coverArt, parameters: params)
    return try LocalFileManager.shared.moveFile(
      source: tempFile, target: LocalFileManager.shared.fileURL(for: Self.coverPath(id: id)),
      forceOverride: overwrite)
  }

  /// `suffix` and `bitRate` describe the file as downloaded, which may be
  /// converted from the song's original.
  /// False when the record could not be saved.
  @discardableResult
  func saveDownload(
    albumId: String, albumName: String?, song: Song, suffix: String, bitRate: Int,
    isFromPlaylist: Bool = false, playlistIndex: Int = -1
  ) -> Bool {
    let songId = isFromPlaylist ? "pl:\(albumId):\(song.mediaFileId)" : song.id
    let position = isFromPlaylist ? Int32(playlistIndex) : Int32(-1)

    let checkExistingSong = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.id, value: songId, limit: 1)

    let fileURL = Self.downloadPath(
      collectionId: albumId, mediaFileId: isFromPlaylist ? song.mediaFileId : song.id,
      suffix: suffix)

    let resolvedAlbumName = !song.albumName.isEmpty ? song.albumName : (albumName ?? "")

    // A download at another bitrate has another suffix; the old file goes.
    var replacedFile: String?
    if let existingSong = checkExistingSong.first {
      if let old = existingSong.fileURL, !old.isEmpty, old != fileURL { replacedFile = old }
      existingSong.fileURL = fileURL
      existingSong.albumName = resolvedAlbumName
      existingSong.songAlbumId = song.albumId
      existingSong.suffix = suffix
      existingSong.bitRate = Int64(bitRate)
      existingSong.position = position
      existingSong.explicitStatus = song.explicitStatus.rawValue
    } else {
      let downloadedSong = SongEntity(context: CoreDataManager.shared.viewContext)

      downloadedSong.albumId = albumId
      downloadedSong.songAlbumId = song.albumId
      downloadedSong.albumName = resolvedAlbumName
      downloadedSong.id = songId
      downloadedSong.title = song.title
      downloadedSong.artistName = song.artist
      downloadedSong.bitRate = Int64(bitRate)
      downloadedSong.sampleRate = Int32(song.sampleRate)
      downloadedSong.discNumber = Int16(song.discNumber)
      downloadedSong.trackNumber = Int16(song.trackNumber)
      downloadedSong.suffix = suffix
      downloadedSong.duration = song.duration
      downloadedSong.fileURL = fileURL
      downloadedSong.mediaFileId = isFromPlaylist ? song.mediaFileId : song.id
      downloadedSong.position = position
      downloadedSong.explicitStatus = song.explicitStatus.rawValue
    }

    guard CoreDataManager.shared.saveRecord() else { return false }
    if let replacedFile {
      try? FileManager.default.removeItem(at: LocalFileManager.shared.fileURL(for: replacedFile))
    }
    return true
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

  /// The download of one song for `DownloadSession`: the original file for
  /// `kbps` 0, else an MP3 the server converts, which has no length.
  func downloadRequest(mediaFileId: String, kbps: Int) -> URLRequest? {
    guard !UserDefaultsManager.serverBaseURL.isEmpty else { return nil }
    let format = TranscodingSettings.convertedFormat(kbps: kbps) ?? TranscodingSettings.sourceFormat
    let params: [String: Any] = ["id": mediaFileId, "format": format, "bitrate": kbps]
    return URL(string: subsonicURL(endpoint: API.SubsonicEndpoint.download, parameters: params))
      .map { URLRequest(url: $0) }
  }

  /// Removes a downloaded album or playlist: every song file at its stored
  /// path, the collection folder and the collection's cover, then its
  /// records. Records go even when a folder is already missing, so nothing is
  /// left dangling.
  func removeDownloadedCollection(
    id: String, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // A song still downloading would bring the collection back.
    DownloadSession.shared.cancel(collectionId: id)

    let songs = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id)

    var paths = songs.compactMap(\.fileURL).filter { !$0.isEmpty }
    paths += ["Media/\(id)", Self.coverPath(id: id)]

    for path in paths {
      let url = LocalFileManager.shared.fileURL(for: path)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }

      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        completion(.failure(error))
        return
      }
    }

    CoreDataManager.shared.deleteRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: id)
    CoreDataManager.shared.deleteRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id)
    DownloadSession.shared.downloadsRemoved.send()

    completion(.success(()))
  }
}
