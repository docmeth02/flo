//
//  PlaybackService.swift
//  flo
//
//  Created by rizaldy on 28/08/24.
//

import CoreData
import Foundation

class PlaybackService {
  static let shared = PlaybackService()

  /// The queue in play order. A queue stored before the position attribute
  /// existed has every position at 0, but its batch insert assigned primary
  /// keys in queue order, so they break the tie.
  func getQueue() -> [QueueEntity] {
    return CoreDataManager.shared.getRecordsByEntity(entity: QueueEntity.self)
      .sorted { ($0.position, Self.primaryKey($0)) < ($1.position, Self.primaryKey($1)) }
  }

  private static func primaryKey(_ entity: QueueEntity) -> Int {
    // Permanent object IDs end in "p<primary key>".
    Int(entity.objectID.uriRepresentation().lastPathComponent.dropFirst()) ?? .max
  }

  func clearQueue() {
    CoreDataManager.shared.deleteRecords(entity: QueueEntity.self)
  }

  /// Replaces the stored queue in one save, so a failure keeps the old queue.
  /// Returns the new queue, or nothing if it could not be stored.
  func addToQueue<T: Playable>(item: T, isFromLocal: Bool = false) -> [QueueEntity] {
    let context = CoreDataManager.shared.viewContext
    let oldQueue = CoreDataManager.shared.getRecordsByEntity(entity: QueueEntity.self)

    let isPlaylist = item is Playlist
    let isPlaylistAlbum =
      (item as? Album).map { album in
        album.artist == "Various Artists" && album.albumArtist == "Various Artists"
          && album.genre.contains(" by ")
      } ?? false

    let isFromPlaylist = isPlaylist || isPlaylistAlbum

    for (index, song) in item.songs.enumerated() {
      let entity = QueueEntity(context: context)
      entity.id = song.mediaFileId == "" ? song.id : song.mediaFileId
      entity.albumId = song.albumId
      entity.albumName = song.albumName.isEmpty ? item.name : song.albumName
      entity.contextName = item.name
      entity.artistName = song.artist
      entity.bitRate = Int16(clamping: song.bitRate)
      entity.sampleRate = Int32(clamping: song.sampleRate)
      entity.songName = song.title
      entity.suffix = song.suffix
      entity.isFromPlaylist = isFromPlaylist
      entity.isFromLocal = isFromLocal
      entity.duration = song.duration
      entity.position = Int32(index)
    }
    oldQueue.forEach(context.delete)

    do {
      try context.save()
    } catch {
      context.rollback()
      print("Failed to store the queue: \(error.localizedDescription)")
      return []
    }

    return self.getQueue()
  }
}
