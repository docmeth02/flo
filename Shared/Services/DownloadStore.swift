//
//  DownloadStore.swift
//  Ownwave
//

import Foundation

/// The downloaded albums and playlists: their records in Core Data and their
/// files and covers on disk.
enum DownloadStore {
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
  static func downloadedFileURL(mediaFileId id: String) -> URL? {
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
  static func localFileURL(mediaFileId id: String) -> URL? {
    downloadedFileURL(mediaFileId: id) ?? StreamCacheManager.shared.cachedFileURL(mediaFileId: id)
  }

  /// The downloaded albums and playlists, each as an album.
  static func downloadedAlbums() -> [Album] {
    CoreDataManager.shared.getRecordsByEntity(entity: PlaylistEntity.self).map { entity in
      var album = Album(from: entity)
      album.isPlaylist = isPlaylistDownload(id: album.id)
      return album
    }
  }

  static func getSongsByAlbumId(albumId: String) -> [Song] {
    let sortByDiscNumber = NSSortDescriptor(key: "discNumber", ascending: true)
    let sortByTrackNumber = NSSortDescriptor(key: "trackNumber", ascending: true)

    return CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: albumId,
      sortDescriptors: [sortByDiscNumber, sortByTrackNumber]
    ).map(Song.init)
  }

  static func getPlaylistSongs(playlistId: String) -> [Song] {
    let sortByPosition = NSSortDescriptor(key: "position", ascending: true)
    let sortByTrackNumber = NSSortDescriptor(key: "trackNumber", ascending: true)

    return CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: playlistId,
      sortDescriptors: [sortByPosition, sortByTrackNumber]
    ).map(Song.init)
  }

  static func isPlaylistDownload(id: String) -> Bool {
    let songs = CoreDataManager.shared.getRecordByKey(
      entity: SongEntity.self, key: \SongEntity.albumId, value: id, limit: 1)

    return songs.first?.id?.hasPrefix("pl:") ?? false
  }

  static func updatePlaylistPositions(playlistId: String, songs: [Song]) {
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
  static func downloadedCoverPath(albumId: String) -> String? {
    guard !albumId.isEmpty else { return nil }
    let path = LocalFileManager.shared.fileURL(for: Self.coverPath(id: albumId)).path
    return FileManager.default.fileExists(atPath: path) ? path : nil
  }

  /// The album's cover: its download, else the cover cache, else the server.
  static func coverURL(albumId: String) -> String {
    downloadedCoverPath(albumId: albumId)
      ?? CoverArtCacheManager.shared.cachedFilePath(albumId: albumId)
      ?? subsonicURL(
        endpoint: API.SubsonicEndpoint.coverArt,
        parameters: ["id": "al-\(albumId)", "size": AppPlatform.coverArtSize])
  }

  /// `suffix` and `bitRate` describe the file as downloaded, which may be
  /// converted from the song's original.
  /// False when the record could not be saved.
  @discardableResult
  static func saveDownload(
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
  private static func collectionEntity(id: String) -> PlaylistEntity {
    CoreDataManager.shared.getRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: id, limit: 1
    ).first ?? PlaylistEntity(context: CoreDataManager.shared.viewContext)
  }

  /// Whether the collection has its record, with or without songs.
  static func hasRecord(collectionId: String) -> Bool {
    !CoreDataManager.shared.getRecordByKey(
      entity: PlaylistEntity.self, key: \PlaylistEntity.id, value: collectionId, limit: 1
    ).isEmpty
  }

  static func saveAlbum(_ albumToDownload: Album) {
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

  static func savePlaylist(_ playlistToDownload: Playlist) {
    let playlist = collectionEntity(id: playlistToDownload.id)

    playlist.id = playlistToDownload.id
    playlist.name = playlistToDownload.name
    playlist.genre = "\(playlistToDownload.comment) by \(playlistToDownload.ownerName)"

    playlist.albumArtist = "Various Artists"
    playlist.artistName = "Various Artists"

    CoreDataManager.shared.saveRecord()
  }

  /// Media ids of the collection's downloaded songs.
  static func downloadedMediaFileIds(collectionId: String) -> Set<String> {
    Set(
      CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.albumId, value: collectionId
      ).compactMap(\.mediaFileId))
  }

  /// Media ids that play without the server: downloaded or stream cached.
  static func localMediaFileIds() -> Set<String> {
    Set(
      CoreDataManager.shared.getRecordsByEntity(entity: SongEntity.self).compactMap(\.mediaFileId)
    )
    .union(StreamCacheManager.shared.readyMediaFileIds())
  }

  static func checkIfAlbumDownloaded(albumID: String) -> Bool {
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

  /// Removes a downloaded album or playlist: every song file at its stored
  /// path, the collection folder and the collection's cover, then its
  /// records. Records go even when a folder is already missing, so nothing is
  /// left dangling.
  static func removeDownloadedCollection(
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
