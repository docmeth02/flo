//
//  HistorySyncMonitor.swift
//  flo
//

import CloudKit
import CoreData
import Foundation

/// Observes CloudKit mirroring of the listening-history store: publishes the
/// last sync outcome for the Preferences UI and deduplicates imported rows.
final class HistorySyncMonitor: ObservableObject {
  static let shared = HistorySyncMonitor()

  @Published private(set) var lastSyncDate: Date?
  @Published private(set) var lastErrorDescription: String?

  private var observers: [NSObjectProtocol] = []
  private var dedupWork: DispatchWorkItem?

  private init() {}

  func start() {
    guard observers.isEmpty else { return }

    let center = NotificationCenter.default

    observers.append(
      center.addObserver(
        forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
            as? NSPersistentCloudKitContainer.Event,
          event.endDate != nil
        else { return }

        self?.lastSyncDate = event.endDate
        self?.lastErrorDescription = event.error?.localizedDescription
      })

    observers.append(
      center.addObserver(
        forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
      ) { [weak self] _ in
        self?.scheduleDedup()
      })
  }

  /// Debounced: imports arrive in bursts, one pass at the end is enough.
  private func scheduleDedup() {
    dedupWork?.cancel()

    let work = DispatchWorkItem { Self.dedupImportedHistory() }
    dedupWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
  }

  /// Two devices can hold the same event (restored backups, interrupted
  /// migrations) and CloudKit uploads them as distinct records. Keep one row
  /// per eventID; regular deletes so the cleanup mirrors back to CloudKit.
  private static func dedupImportedHistory() {
    guard
      let container = CoreDataManager.shared.persistentContainer
        as? NSPersistentCloudKitContainer
    else { return }

    let context = container.newBackgroundContext()

    context.perform {
      let idRequest = NSFetchRequest<NSDictionary>(entityName: "HistoryEntity")
      idRequest.resultType = .dictionaryResultType
      idRequest.propertiesToFetch = ["eventID"]

      guard let rows = try? context.fetch(idRequest) else { return }

      var counts: [UUID: Int] = [:]
      for row in rows {
        if let id = row["eventID"] as? UUID {
          counts[id, default: 0] += 1
        }
      }

      let duplicated = counts.filter { $0.value > 1 }.map { $0.key }
      guard !duplicated.isEmpty else { return }

      for eventID in duplicated {
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "eventID == %@", eventID as CVarArg)

        guard let matches = try? context.fetch(request), matches.count > 1 else { continue }

        // The keeper must be chosen identically on every device, or two
        // concurrent dedup passes can each delete the other's keeper and the
        // event vanishes everywhere. CloudKit record names are the only
        // identity that is the same on all devices; rows without one (not
        // yet exported) are left alone until a later pass.
        let named = matches.compactMap { row -> (HistoryEntity, String)? in
          guard let recordID = container.recordID(for: row.objectID) else { return nil }
          return (row, recordID.recordName)
        }
        guard named.count == matches.count,
          let keeperName = named.map({ $0.1 }).min()
        else { continue }

        for (row, name) in named where name != keeperName {
          context.delete(row)
        }
      }

      try? context.save()
    }
  }
}
