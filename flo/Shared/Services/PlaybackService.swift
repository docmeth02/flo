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

  private let injectedContext: NSManagedObjectContext?
  // Resolved per call: the shared store may only open after this exists.
  private var context: NSManagedObjectContext {
    injectedContext ?? CoreDataManager.shared.viewContext
  }

  /// `context` is for tests; the app uses the shared view context.
  init(context: NSManagedObjectContext? = nil) {
    injectedContext = context
  }

  /// The queue in play order. A queue stored before the position attribute
  /// existed has every position at 0, but its batch insert assigned primary
  /// keys in queue order, so they break the tie.
  func getQueue() -> [QueueEntity] {
    let request = QueueEntity.fetchRequest()
    return ((try? context.fetch(request)) ?? [])
      .sorted { ($0.position, Self.primaryKey($0)) < ($1.position, Self.primaryKey($1)) }
  }

  private static func primaryKey(_ entity: QueueEntity) -> Int {
    // Permanent object IDs end in "p<primary key>".
    Int(entity.objectID.uriRepresentation().lastPathComponent.dropFirst()) ?? .max
  }

  func clearQueue() {
    CoreDataManager.shared.deleteRecords(entity: QueueEntity.self)
  }

  /// A new, unsaved queue row for `song`; `context` names the collection it
  /// came from, which the journal reads as the song's origin.
  func makeEntry(
    song: Song, context name: String, isFromPlaylist: Bool, isFromLocal: Bool
  ) -> QueueEntity {
    let entity = QueueEntity(context: context)
    entity.id = song.mediaFileId == "" ? song.id : song.mediaFileId
    entity.albumId = song.albumId
    entity.albumName = song.albumName.isEmpty ? name : song.albumName
    entity.contextName = name
    entity.artistName = song.artist
    entity.bitRate = Int16(clamping: song.bitRate)
    entity.sampleRate = Int32(clamping: song.sampleRate)
    entity.songName = song.title
    entity.suffix = song.suffix
    entity.isFromPlaylist = isFromPlaylist
    entity.isFromLocal = isFromLocal
    entity.duration = song.duration
    entity.explicitStatus = song.explicitStatus.rawValue
    return entity
  }

  /// Numbers `order` as the stored queue, deletes the rows that are no longer
  /// in it and saves once. On failure every unsaved change is rolled back
  /// and false returned, so the stored queue stays as it was.
  @discardableResult
  func store(order: [QueueEntity]) -> Bool {
    let kept = Set(order.map(\.objectID))
    getQueue().filter { !kept.contains($0.objectID) }.forEach(context.delete)
    for (index, entity) in order.enumerated() where entity.position != Int32(index) {
      entity.position = Int32(index)
    }

    do {
      try context.save()
      return true
    } catch {
      context.rollback()
      debugLog("Failed to store the queue: \(error.localizedDescription)")
      return false
    }
  }

  /// Whether songs played from `item` come from a playlist: a playlist, or
  /// one played as an album, which carries "Various Artists" and its owner
  /// in the genre.
  static func isPlaylist<T: Playable>(_ item: T) -> Bool {
    if item is Playlist { return true }
    guard let album = item as? Album else { return false }
    return album.artist == "Various Artists" && album.albumArtist == "Various Artists"
      && album.genre.contains(" by ")
  }

  /// Replaces the stored queue in one save, so a failure keeps the old queue.
  /// Returns the new queue, or nothing if it could not be stored.
  func addToQueue<T: Playable>(item: T, isFromLocal: Bool = false) -> [QueueEntity] {
    let entries = item.songs.map {
      makeEntry(
        song: $0, context: item.name, isFromPlaylist: Self.isPlaylist(item),
        isFromLocal: isFromLocal)
    }
    return store(order: entries) ? entries : []
  }
}
