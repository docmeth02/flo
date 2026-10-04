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

/// The play order and the stored order of the queue, and the edits the user
/// makes to them. Every edit changes the play order and, while shuffling, the
/// stored order the same way; unshuffled, the stored order is the play order
/// and `stored` is left alone. Rows are matched by identity, and the current
/// row is never removed or moved.
struct QueueOrders<Row: AnyObject> {
  private(set) var played: [Row]
  private(set) var stored: [Row]
  /// Where the current row is in the play order.
  private(set) var currentIndex: Int
  let isShuffling: Bool
  private let current: Row

  /// `currentIndex` must be a valid index of `played`.
  init(played: [Row], stored: [Row], currentIndex: Int, isShuffling: Bool) {
    self.played = played
    self.stored = stored
    self.currentIndex = currentIndex
    self.isShuffling = isShuffling
    current = played[currentIndex]
  }

  /// The order that is saved: the stored order while shuffling.
  var toStore: [Row] { isShuffling ? stored : played }

  /// Play Next.
  mutating func insertAfterCurrent(_ rows: [Row]) {
    let current = current
    edit { Self.insert(rows, after: current, in: &$0) }
  }

  /// Add to Queue.
  mutating func append(_ rows: [Row]) {
    edit { $0.append(contentsOf: rows) }
  }

  mutating func remove(_ row: Row) {
    edit { $0.removeAll { $0 === row } }
  }

  mutating func moveNext(_ row: Row) {
    let current = current
    edit { order in
      order.removeAll { $0 === row }
      Self.insert([row], after: current, in: &order)
    }
  }

  /// Undo of a removal: puts `row` back at `index` in the play order, but
  /// never before the current row, where it would not play again, and at
  /// `storedIndex` in the stored order; at the end where the order got shorter.
  mutating func reinsert(_ row: Row, at index: Int, storedIndex: Int) {
    played.insert(row, at: min(max(index, currentIndex + 1), played.count))
    if isShuffling { stored.insert(row, at: min(storedIndex, stored.count)) }
    updateCurrentIndex()
  }

  private mutating func edit(_ change: (inout [Row]) -> Void) {
    change(&played)
    if isShuffling { change(&stored) }
    updateCurrentIndex()
  }

  private mutating func updateCurrentIndex() {
    currentIndex = played.firstIndex { $0 === current } ?? currentIndex
  }

  private static func insert(_ rows: [Row], after current: Row, in order: inout [Row]) {
    order.insert(contentsOf: rows, at: (order.firstIndex { $0 === current } ?? order.count - 1) + 1)
  }
}

/// Play Next, Add to Queue, remove and Undo. Every edit goes through
/// `QueueOrders` on the play order (`queue`) and the stored order
/// (`unshuffledQueue`), saves in one go and publishes both only when that
/// worked.
extension WatchPlayerViewModel {
  /// Puts `songs` right after the current song. Starts them instead when
  /// nothing plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func playNext(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    guard !songs.isEmpty else { return false }
    guard isEditable else { return start(songs, context: context, isFromPlaylist: isFromPlaylist) }
    let entries = makeEntries(songs, context: context, isFromPlaylist: isFromPlaylist)
    return editQueue { $0.insertAfterCurrent(entries) } && playOnIfEnded()
  }

  /// Puts `songs` at the end of the queue. Starts them instead when nothing
  /// plays or a live radio does. Returns whether the queue changed.
  @discardableResult
  func appendToQueue(_ songs: [Song], context: String, isFromPlaylist: Bool = false) -> Bool {
    guard !songs.isEmpty else { return false }
    guard isEditable else { return start(songs, context: context, isFromPlaylist: isFromPlaylist) }
    let entries = makeEntries(songs, context: context, isFromPlaylist: isFromPlaylist)
    return editQueue { $0.append(entries) } && playOnIfEnded()
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
    return editQueue { $0.remove(entity) } ? removed : nil
  }

  /// Puts a removed row back where it was, or at the end when the queue
  /// changed so much that its place is gone.
  @discardableResult
  func undoRemove(_ entry: RemovedQueueEntry) -> Bool {
    guard isEditable else { return false }
    let entity = PlaybackService.shared.makeEntry(
      song: entry.song, context: entry.context, isFromPlaylist: entry.isFromPlaylist,
      isFromLocal: entry.isFromLocal)
    return editQueue { $0.reinsert(entity, at: entry.index, storedIndex: entry.storedIndex) }
  }

  /// Moves the row at `index` (play order) right after the current song.
  @discardableResult
  func moveToNext(at index: Int) -> Bool {
    guard isEditable, queue.indices.contains(index), index != activeQueueIdx else { return false }
    let entity = queue[index]
    return editQueue { $0.moveNext(entity) }
  }

  // A live radio's queue is the station alone.
  private var isEditable: Bool { hasNowPlaying() && !isLiveRadio }

  /// Songs queued after the queue ran out play right away, rather than after
  /// the ended song plays again. Always true: the queue did change.
  private func playOnIfEnded() -> Bool {
    if isFinished { nextSong() }
    return true
  }

  private func start(_ songs: [Song], context: String, isFromPlaylist: Bool) -> Bool {
    let item = SongCollection(id: context, name: context, songs: songs, isPlaylist: isFromPlaylist)
    return playItem(item: item, isFromLocal: false)
  }

  private func makeEntries(_ songs: [Song], context: String, isFromPlaylist: Bool) -> [QueueEntity] {
    songs.map {
      PlaybackService.shared.makeEntry(
        song: $0, context: context, isFromPlaylist: isFromPlaylist, isFromLocal: false)
    }
  }

  /// Applies `edit` to copies of both orders, stores the order that is saved
  /// and only then publishes both. A failed save rolls back and leaves
  /// everything as it was.
  private func editQueue(_ edit: (inout QueueOrders<QueueEntity>) -> Void) -> Bool {
    var orders = QueueOrders(
      played: queue, stored: unshuffledQueue, currentIndex: activeQueueIdx,
      isShuffling: isShuffling)
    edit(&orders)
    guard PlaybackService.shared.store(order: orders.toStore) else { return false }

    unshuffledQueue = orders.stored
    queue = orders.played
    activeQueueIdx = orders.currentIndex
    persistActiveIndex()
    persistShuffleOrder()
    precacheUpcoming()
    return true
  }
}
