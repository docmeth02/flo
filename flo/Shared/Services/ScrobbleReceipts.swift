import Foundation

/// Outbox rows the server accepted, written to a small file before the row is
/// deleted, so a delete that fails to save never sends the listen again, not
/// even after a relaunch. A file that cannot be written leaves the receipt in
/// memory, which protects this process only. Main thread.
final class ScrobbleReceipts {
  struct Receipt: Codable, Hashable {
    let account: String
    /// The outbox row's object id URI, stable across launches.
    let row: String
  }

  static let defaultURL = URL.applicationSupportDirectory
    .appendingPathComponent("scrobble-receipts.json")

  private let fileURL: URL
  private var receipts: Set<Receipt>

  init(fileURL: URL = defaultURL) {
    self.fileURL = fileURL
    do {
      receipts = try JSONDecoder().decode(Set<Receipt>.self, from: Data(contentsOf: fileURL))
    } catch CocoaError.fileReadNoSuchFile {
      receipts = []
    } catch {
      RequestLog.shared.note("scrobble receipts unreadable: \(error)")
      receipts = []
    }
  }

  func contains(_ receipt: Receipt) -> Bool {
    receipts.contains(receipt)
  }

  func insert(_ receipt: Receipt) {
    guard receipts.insert(receipt).inserted else { return }
    save()
  }

  func remove(_ receipt: Receipt) {
    guard receipts.remove(receipt) != nil else { return }
    save()
  }

  /// Drops the receipts whose row is gone.
  func keep(rows: Set<String>) {
    let kept = receipts.filter { rows.contains($0.row) }
    guard kept.count != receipts.count else { return }
    receipts = kept
    save()
  }

  func removeAll() {
    guard !receipts.isEmpty else { return }
    receipts = []
    save()
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(receipts).write(to: fileURL, options: .atomic)
    } catch {
      RequestLog.shared.note("scrobble receipts not saved: \(error)")
    }
  }
}
