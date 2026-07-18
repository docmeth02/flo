//
//  CoreDataManager.swift
//  flo
//
//  Created by rizaldy on 29/06/24.
//

@preconcurrency import CoreData
import CryptoKit
import Foundation

class CoreDataManager: ObservableObject {
  static let shared = CoreDataManager()

  private init() {}

  private static let modelName = "flo"
  private static let localConfiguration = "Local"
  private static let cloudConfiguration = "Cloud"
  private static let historyMigrationDoneKey = "coreData.historyMigrationV2.done"

  static let localStoreURL = NSPersistentContainer.defaultDirectoryURL()
    .appendingPathComponent("flo.sqlite")
  static let historyStoreURL = NSPersistentContainer.defaultDirectoryURL()
    .appendingPathComponent("flo-history.sqlite")

  // One shared model instance for the container AND the migration stack — two
  // instances of the same model cause duplicate NSEntityDescription class claims.
  private static let model: NSManagedObjectModel = {
    guard let url = Bundle.main.url(forResource: modelName, withExtension: "momd"),
      let model = NSManagedObjectModel(contentsOf: url)
    else {
      fatalError("failed to load Core Data model \(modelName)")
    }
    return model
  }()

  /// False when the history store failed to load — history reads/writes are
  /// skipped for the session while queue/downloads/playlists keep working.
  private(set) var isHistoryStoreAvailable: Bool = true

  private static func inMemoryContainer() -> NSPersistentContainer {
    let container = NSPersistentContainer(name: modelName, managedObjectModel: model)
    let description = NSPersistentStoreDescription()

    description.type = NSInMemoryStoreType
    description.shouldAddStoreAsynchronously = false

    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
      if let error {
        print("Failed to create in-memory store: \(error.localizedDescription)")
      }
    }

    container.viewContext.automaticallyMergesChangesFromParent = true

    return container
  }

  private static func historyStoreDescription() -> NSPersistentStoreDescription {
    let description = NSPersistentStoreDescription(url: historyStoreURL)
    description.configuration = cloudConfiguration
    description.shouldAddStoreAsynchronously = false
    // Tracking from day one: rows written while sync is off still produce
    // persistent-history transactions, so they can export once mirroring is
    // attached in a later release.
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    description.setOption(
      true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    return description
  }

  private static func makeContainer(syncEnabled: Bool) -> (
    container: NSPersistentContainer, historyAvailable: Bool
  ) {
    let container = NSPersistentContainer(name: modelName, managedObjectModel: model)

    let local = NSPersistentStoreDescription(url: localStoreURL)
    local.configuration = localConfiguration
    local.shouldAddStoreAsynchronously = false

    container.persistentStoreDescriptions = [local, historyStoreDescription()]

    var errorsByConfiguration: [String: Error] = [:]

    container.loadPersistentStores { description, error in
      if let error {
        errorsByConfiguration[description.configuration ?? ""] = error
      }
    }

    if let localError = errorsByConfiguration[localConfiguration] {
      print("failed to load local store: \(localError.localizedDescription)")

      return (Self.inMemoryContainer(), true)
    }

    let historyAvailable = errorsByConfiguration[cloudConfiguration] == nil
    if !historyAvailable {
      print(
        "failed to load history store: "
          + "\(errorsByConfiguration[cloudConfiguration]!.localizedDescription)")
    }

    container.viewContext.automaticallyMergesChangesFromParent = true

    return (container, historyAvailable)
  }

  private let containerLock = NSLock()
  private var loadedContainer: NSPersistentContainer?

  // Not a lazy var: the first access runs the history migration, and lazy
  // initialization is not thread-safe.
  var persistentContainer: NSPersistentContainer {
    containerLock.lock()
    defer { containerLock.unlock() }

    if let loadedContainer {
      return loadedContainer
    }

    Self.migrateLegacyHistoryIfNeeded()

    let (container, historyAvailable) = Self.makeContainer(syncEnabled: false)
    self.isHistoryStoreAvailable = historyAvailable
    self.loadedContainer = container

    return container
  }

  // MARK: - Legacy history migration

  /// Moves HistoryEntity rows out of the original single store into the
  /// dedicated history store. Idempotent and crash-recoverable: rows carry a
  /// stable eventID derived from their legacy objectID, so a retry never
  /// duplicates them; the UserDefaults flag is only a fast path.
  private static func migrateLegacyHistoryIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: historyMigrationDoneKey) else { return }

    guard FileManager.default.fileExists(atPath: localStoreURL.path) else {
      UserDefaults.standard.set(true, forKey: historyMigrationDoneKey)
      return
    }

    // Migrating while logged out would stamp rows with an empty scope and
    // orphan them from every future account-scoped read. Wait for a login and
    // migrate on a later launch.
    let scope = AuthService.shared.currentLibraryScope
    guard !scope.isEmpty else { return }

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let migrationOptions: [String: Any] = [
      NSMigratePersistentStoresAutomaticallyOption: true,
      NSInferMappingModelAutomaticallyOption: true,
    ]

    let legacyStore: NSPersistentStore
    let historyStore: NSPersistentStore

    do {
      // nil configuration = default configuration = all entities, so the
      // legacy HistoryEntity rows are reachable. This add also performs the
      // in-place lightweight v1 -> v2 migration of the legacy file.
      legacyStore = try coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil, at: localStoreURL,
        options: migrationOptions)

      var historyOptions = migrationOptions
      historyOptions[NSPersistentHistoryTrackingKey] = true
      historyOptions[NSPersistentStoreRemoteChangeNotificationPostOptionKey] = true

      historyStore = try coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: cloudConfiguration, at: historyStoreURL,
        options: historyOptions)
    } catch {
      print("history migration: failed to open stores: \(error.localizedDescription)")
      return
    }

    defer {
      try? coordinator.remove(legacyStore)
      try? coordinator.remove(historyStore)
    }

    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator

    context.performAndWait {
      do {
        let legacyRequest = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        legacyRequest.affectedStores = [legacyStore]
        legacyRequest.fetchBatchSize = 500

        let legacyRows = try context.fetch(legacyRequest)

        if legacyRows.isEmpty {
          UserDefaults.standard.set(true, forKey: historyMigrationDoneKey)
          return
        }

        let existingRequest = NSFetchRequest<NSDictionary>(entityName: "HistoryEntity")
        existingRequest.affectedStores = [historyStore]
        existingRequest.resultType = .dictionaryResultType
        existingRequest.propertiesToFetch = ["eventID"]

        let migratedIDs = Set(
          try context.fetch(existingRequest).compactMap { $0["eventID"] as? UUID })

        var pending = 0
        for row in legacyRows {
          let eventID = stableEventID(for: row.objectID)
          guard !migratedIDs.contains(eventID) else { continue }

          let copy = HistoryEntity(context: context)
          context.assign(copy, to: historyStore)
          copy.albumId = row.albumId
          copy.albumName = row.albumName
          copy.artistName = row.artistName
          copy.songId = row.songId
          copy.timestamp = row.timestamp
          copy.trackName = row.trackName
          copy.eventID = eventID
          copy.libraryScope = scope

          pending += 1
          if pending >= 500 {
            try context.save()
            pending = 0
          }
        }
        if pending > 0 {
          try context.save()
        }

        let deleteFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: deleteFetch)
        deleteRequest.affectedStores = [legacyStore]
        try context.execute(deleteRequest)
        try context.save()

        UserDefaults.standard.set(true, forKey: historyMigrationDoneKey)
      } catch {
        print("history migration failed, will retry next launch: \(error.localizedDescription)")
      }
    }
  }

  /// Stable per-row identity across migration retries: the legacy objectID URI
  /// survives lightweight migration, and it distinguishes even rows whose
  /// content is identical.
  private static func stableEventID(for objectID: NSManagedObjectID) -> UUID {
    let digest = SHA256.hash(data: Data(objectID.uriRepresentation().absoluteString.utf8))
    let bytes = Array(digest.prefix(16))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  var viewContext: NSManagedObjectContext {
    return self.persistentContainer.viewContext
  }

  func getRecordsByEntity<T: NSManagedObject>(
    entity: T.Type, sortDescriptors: [NSSortDescriptor]? = nil
  ) -> [T] {
    let request: NSFetchRequest<T> = NSFetchRequest<T>(entityName: String(describing: T.self))

    request.sortDescriptors = sortDescriptors

    do {
      return try self.viewContext.fetch(request)
    } catch {
      return []
    }
  }

  func getRecordsByEntityBatched<T: NSManagedObject>(
    entity: T.Type, predicate: NSPredicate? = nil, sortDescriptors: [NSSortDescriptor]? = nil,
    batchSize: Int = 100
  ) async -> [T] {
    let request: NSFetchRequest<T> = NSFetchRequest<T>(entityName: String(describing: T.self))

    request.predicate = predicate
    request.sortDescriptors = sortDescriptors
    request.fetchBatchSize = batchSize

    let context = self.viewContext

    return await withCheckedContinuation { continuation in
      context.perform {
        do {
          let results = try context.fetch(request)

          continuation.resume(returning: results)
        } catch {
          print("Fetch error: \(error)")

          continuation.resume(returning: [])
        }
      }
    }
  }

  func getRecordByKey<T: NSManagedObject, V>(
    entity: T.Type,
    key: KeyPath<T, V>,
    value: V?,
    limit: Int = 0,
    sortDescriptors: [NSSortDescriptor]? = nil
  ) -> [T] {
    let request: NSFetchRequest<T> = NSFetchRequest<T>(entityName: String(describing: T.self))

    guard let keyPathString = key._kvcKeyPathString else {
      return []
    }

    let predicate: NSPredicate

    if let identifier = value as? CVarArg {
      predicate = NSPredicate(format: "%K == %@", keyPathString, identifier)
    } else {
      predicate = NSPredicate(format: "%K == NULL", keyPathString)
    }

    request.predicate = predicate
    request.fetchLimit = limit > 0 ? limit : 0
    request.sortDescriptors = sortDescriptors

    do {
      return try self.viewContext.fetch(request)
    } catch let error {
      print(error.localizedDescription)

      return []
    }
  }

  func countRecords<T: NSManagedObject>(entity: T.Type) -> Int {
    let request: NSFetchRequest<T> = NSFetchRequest<T>(entityName: String(describing: T.self))

    request.resultType = .countResultType

    do {
      let count = try self.viewContext.count(for: request)
      return count
    } catch {
      print(error.localizedDescription)

      return 0
    }
  }

  /// A single save spanning entities from both stores is not atomic across
  /// stores (Core Data commits per store) — no caller may mix History and
  /// Local writes in one save.
  func saveRecord() {
    do {
      try self.viewContext.save()
    } catch {
      self.viewContext.rollback()

      print(error.localizedDescription)
    }
  }

  func deleteRecords<T: NSManagedObject>(entity: T.Type) {
    let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest<NSFetchRequestResult>(
      entityName: String(describing: T.self))
    let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

    do {
      try self.viewContext.execute(deleteRequest)
      try self.viewContext.save()
    } catch {
      print("Failed to delete records: \(error.localizedDescription)")
    }
  }

  func deleteRecordByKey<T: NSManagedObject, V>(
    entity: T.Type,
    key: KeyPath<T, V>,
    value: V?
  ) {
    guard let keyPathString = key._kvcKeyPathString else {
      return
    }

    let predicate: NSPredicate

    if let identifier = value as? CVarArg {
      predicate = NSPredicate(format: "%K == %@", keyPathString, identifier)
    } else {
      predicate = NSPredicate(format: "%K == NULL", keyPathString)
    }

    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: T.self))
    fetchRequest.predicate = predicate

    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

    do {
      try self.viewContext.execute(deleteRequest)
      try self.viewContext.save()
    } catch {
      print("Failed to delete records: \(error.localizedDescription)")
    }
  }

  func clearEverything() {
    let entities = ["QueueEntity", "SongEntity", "PlaylistEntity", "CacheEntity"]

    for entity in entities {
      let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
      let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

      do {
        try self.viewContext.execute(batchDeleteRequest)

        print("Successfully deleted all records for \(entity).")
      } catch {
        print("Failed to delete records for \(entity): \(error.localizedDescription)")
      }
    }

    do {
      try self.viewContext.save()
    } catch {
      print("Failed to save context: \(error.localizedDescription)")
    }
  }
}
