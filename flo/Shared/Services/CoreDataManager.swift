//
//  CoreDataManager.swift
//  flo
//
//  Created by rizaldy on 29/06/24.
//

@preconcurrency import CoreData
import Foundation

class CoreDataManager {
  static let shared = CoreDataManager()

  /// True when the store could not be opened and the app runs on a memory
  /// store: nothing written this session survives a relaunch.
  private(set) var isUsingVolatileStore = false

  init() {}

  private static func inMemoryContainer() -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "flo")
    let description = NSPersistentStoreDescription()

    description.type = NSInMemoryStoreType
    description.shouldAddStoreAsynchronously = false

    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
      if let error {
        debugLog("Failed to create in-memory store: \(error.localizedDescription)")
      }
    }

    container.viewContext.automaticallyMergesChangesFromParent = true

    return container
  }

  lazy var persistentContainer: NSPersistentContainer = {
    // A transient failure (e.g. storage briefly unavailable at launch) gets a
    // second attempt before falling back to a memory store.
    for attempt in 1...2 {
      if let container = Self.loadPersistentContainer() {
        return container
      }
      if attempt == 1 {
        Self.removeDuplicateCollectionIds()
        Thread.sleep(forTimeInterval: 0.5)
      }
    }

    isUsingVolatileStore = true
    return Self.inMemoryContainer()
  }()

  /// Model version 3 makes downloaded collections unique by id, and the
  /// migration fails on an older store that holds the same id twice (an
  /// album renamed on the server and downloaded again). Opens such a store
  /// with the bundled model it was written with and keeps one record per id.
  /// Version 3 stores already enforce the constraint and are left alone.
  private static func removeDuplicateCollectionIds() {
    let storeURL = NSPersistentContainer.defaultDirectoryURL()
      .appendingPathComponent("flo.sqlite")
    guard
      FileManager.default.fileExists(atPath: storeURL.path),
      let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
        ofType: NSSQLiteStoreType, at: storeURL),
      let model = Bundle.main.urls(forResourcesWithExtension: "mom", subdirectory: "flo.momd")?
        .lazy.compactMap({ NSManagedObjectModel(contentsOf: $0) })
        .first(where: { $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) })
    else { return }

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    guard
      let store = try? coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
    else { return }
    defer { try? coordinator.remove(store) }

    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "PlaylistEntity")
      guard let collections = try? context.fetch(request) else { return }

      var seen = Set<String>()
      for collection in collections.reversed() {
        let id = collection.value(forKey: "id") as? String ?? ""
        if !seen.insert(id).inserted {
          context.delete(collection)
        }
      }
      if context.hasChanges {
        try? context.save()
      }
    }
  }

  private static func loadPersistentContainer() -> NSPersistentContainer? {
    let container = NSPersistentContainer(name: "flo")
    container.persistentStoreDescriptions.forEach { description in
      description.shouldAddStoreAsynchronously = false
      description.shouldMigrateStoreAutomatically = true
      description.shouldInferMappingModelAutomatically = true
    }

    var loadError: Error?

    container.loadPersistentStores { _, error in
      if let error {
        loadError = error
      }
    }

    if let loadError {
      debugLog("failed to load persistent stores: \(loadError.localizedDescription)")
      return nil
    }

    container.viewContext.automaticallyMergesChangesFromParent = true

    return container
  }

  var viewContext: NSManagedObjectContext {
    return self.persistentContainer.viewContext
  }

  /// Runs `work` on a fresh background context and returns its value types.
  /// Saves made there reach the view context through its automatic merging.
  func performBackground<T>(_ work: @escaping (NSManagedObjectContext) -> T) async -> T {
    await withCheckedContinuation { continuation in
      persistentContainer.performBackgroundTask { context in
        continuation.resume(returning: work(context))
      }
    }
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
      debugLog("fetch failed: \(error.localizedDescription)")

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
      debugLog("count failed: \(error.localizedDescription)")

      return 0
    }
  }

  /// Saves the view context; a failed save rolls back its unsaved changes.
  @discardableResult
  func saveRecord() -> Bool {
    do {
      try self.viewContext.save()
      return true
    } catch {
      self.viewContext.rollback()

      debugLog("save failed: \(error.localizedDescription)")
      return false
    }
  }

  func deleteRecords<T: NSManagedObject>(entity: T.Type) {
    batchDelete(entityName: String(describing: T.self))
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

    batchDelete(entityName: String(describing: T.self), predicate: predicate)
  }

  /// Deletes the records of downloaded songs and collections. The play queue
  /// and the stream cache have their own lifecycles and stay untouched.
  func clearDownloads() {
    batchDelete(entityName: "SongEntity")
    batchDelete(entityName: "PlaylistEntity")
  }

  /// Batch-deletes the entity's records matching `predicate` (all when nil)
  /// and merges the deletions into the view context, so objects it still
  /// holds become deleted objects instead of stale ones pointing at missing
  /// rows.
  func batchDelete(entityName: String, predicate: NSPredicate? = nil) {
    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
    fetchRequest.predicate = predicate

    // NSBatchDeleteRequest needs an SQLite store; the in-memory fallback
    // deletes object by object.
    if isUsingVolatileStore {
      let objects = (try? viewContext.fetch(fetchRequest)) as? [NSManagedObject] ?? []
      objects.forEach { viewContext.delete($0) }
      saveRecord()
      return
    }

    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    deleteRequest.resultType = .resultTypeObjectIDs

    do {
      let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult
      let deletedIDs = result?.result as? [NSManagedObjectID] ?? []
      NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSDeletedObjectsKey: deletedIDs], into: [viewContext])
    } catch {
      debugLog("Failed to delete \(entityName) records: \(error.localizedDescription)")
    }
  }
}
