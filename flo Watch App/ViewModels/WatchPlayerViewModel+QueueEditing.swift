//
//  WatchPlayerViewModel+QueueEditing.swift
//  flo Watch App
//

import Foundation

/// A queue row taken out by the user, kept as values so Undo can put it back
/// after its entity is gone.
struct RemovedQueueEntry {
  let song: Song
  let context: String
  let isFromPlaylist: Bool
  let isFromLocal: Bool
  /// Index in the play order the row had.
  let index: Int
  /// Index in the stored order the row had; differs from `index` while shuffling.
  let storedIndex: Int
}

/// Play Next, Add to Queue, remove and Undo. Every edit changes the play
/// order (`queue`) and, while shuffling, the stored order (`unshuffledQueue`)
/// the same way, stores the stored order in one save and publishes both only
/// when that worked. The current song is never removed or moved.
extension WatchPlayerViewModel {
  /// Puts `songs` right after the current song. Starts them instead when
  /// nothing plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func playNext(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    guard !songs.isEmpty else { return false }
    guard isEditable else { return start(songs, context: context) }
    let entries = makeEntries(songs, context: context, isFromPlaylist: isFromPlaylist)
    return editQueue { insertAfterCurrent(entries, in: &$0) }
  }

  /// Puts `songs` at the end of the queue. Starts them instead when nothing
  /// plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func appendToQueue(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    guard !songs.isEmpty else { return false }
    guard isEditable else { return start(songs, context: context) }
    let entries = makeEntries(songs, context: context, isFromPlaylist: isFromPlaylist)
    return editQueue { $0.append(contentsOf: entries) }
  }

  /// Takes the row at `index` (play order) out of the queue. Nil for the
  /// current song, an index out of range, or a failed save.
  func removeFromQueue(at index: Int) -> RemovedQueueEntry? {
    guard isEditable, queue.indices.contains(index), index != activeQueueIdx else { return nil }
    let entity = queue[index]
    // Read before the save deletes the entity.
    let removed = RemovedQueueEntry(
      song: Song(from: entity), context: entity.contextName ?? "",
      isFromPlaylist: entity.isFromPlaylist, isFromLocal: entity.isFromLocal, index: index,
      storedIndex: unshuffledQueue.firstIndex { $0 === entity } ?? index)
    return editQueue { $0.removeAll { $0 === entity } } ? removed : nil
  }

  /// Puts a removed row back where it was, or at the end when the queue
  /// changed so much that its place is gone.
  @discardableResult
  func undoRemove(_ entry: RemovedQueueEntry) -> Bool {
    guard isEditable else { return false }
    let entity = PlaybackService.shared.makeEntry(
      song: entry.song, context: entry.context, isFromPlaylist: entry.isFromPlaylist,
      isFromLocal: entry.isFromLocal)
    return editQueue(
      { $0.insert(entity, at: min(entry.index, $0.count)) },
      stored: { $0.insert(entity, at: min(entry.storedIndex, $0.count)) })
  }

  /// Moves the row at `index` (play order) right after the current song.
  @discardableResult
  func moveToNext(at index: Int) -> Bool {
    guard isEditable, queue.indices.contains(index), index != activeQueueIdx else { return false }
    let entity = queue[index]
    return editQueue { order in
      order.removeAll { $0 === entity }
      insertAfterCurrent([entity], in: &order)
    }
  }

  // A live radio's queue is the station alone.
  private var isEditable: Bool { hasNowPlaying() && !isLiveRadio }

  private func start(_ songs: [Song], context: String) -> Bool {
    playItem(item: SongCollection(id: context, name: context, songs: songs), isFromLocal: false)
  }

  private func makeEntries(_ songs: [Song], context: String, isFromPlaylist: Bool) -> [QueueEntity] {
    songs.map {
      PlaybackService.shared.makeEntry(
        song: $0, context: context, isFromPlaylist: isFromPlaylist, isFromLocal: false)
    }
  }

  private func insertAfterCurrent(_ entries: [QueueEntity], in order: inout [QueueEntity]) {
    let current = nowPlaying
    order.insert(contentsOf: entries, at: (order.firstIndex { $0 === current } ?? order.count - 1) + 1)
  }

  /// Applies `change` to a copy of the play order and, while shuffling,
  /// `changeStored` (`change` unless given) to a copy of the stored order,
  /// stores the stored order and only then publishes both. A failed save
  /// rolls back and leaves everything as it was.
  private func editQueue(
    _ change: (inout [QueueEntity]) -> Void,
    stored changeStored: ((inout [QueueEntity]) -> Void)? = nil
  ) -> Bool {
    let current = nowPlaying
    var played = queue
    var stored = unshuffledQueue
    change(&played)
    if let changeStored, isShuffling {
      changeStored(&stored)
    } else if isShuffling {
      change(&stored)
    }
    guard PlaybackService.shared.store(order: isShuffling ? stored : played) else { return false }

    unshuffledQueue = stored
    queue = played
    activeQueueIdx = played.firstIndex { $0 === current } ?? activeQueueIdx
    persistActiveIndex()
    persistShuffleOrder()
    if hasTriggeredCache { precacheUpcoming() }
    return true
  }
}
