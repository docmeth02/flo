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
}

/// Play Next, Add to Queue, remove and Undo. Every edit changes the play
/// order (`queue`) and, while shuffling, the stored order (`unshuffledQueue`)
/// the same way, stores the stored order in one save and puts both back
/// when that fails. The current song is never removed or moved.
extension WatchPlayerViewModel {
  /// Puts `songs` right after the current song. Starts them instead when
  /// nothing plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func playNext(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    false
  }

  /// Puts `songs` at the end of the queue. Starts them instead when nothing
  /// plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func appendToQueue(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    false
  }

  /// Takes the row at `index` (play order) out of the queue. Nil for the
  /// current song, an index out of range, or a failed save.
  func removeFromQueue(at index: Int) -> RemovedQueueEntry? {
    nil
  }

  /// Puts a removed row back where it was, or at the end when the queue
  /// changed so much that its place is gone.
  @discardableResult
  func undoRemove(_ entry: RemovedQueueEntry) -> Bool {
    false
  }

  /// Moves the row at `index` (play order) right after the current song.
  @discardableResult
  func moveToNext(at index: Int) -> Bool {
    false
  }
}
