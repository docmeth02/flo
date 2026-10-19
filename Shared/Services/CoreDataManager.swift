//
//  CoreDataManager.swift
//  flo
//

@preconcurrency import CoreData
import Foundation

class CoreDataManager {
  static let shared = CoreDataManager()

  /// True when the store could not be opened and the app runs on a memory
  /// store: nothing written this session survives a relaunch.
  private(set) var isUsingVolatileStore = false

  init() {}

  /// Loaded from the bundle that holds this class: the app, or the test
  /// bundle when the tests compile the engine themselves. One instance for
  /// every container, so the entity classes are claimed by one model.
  static let model: NSManagedObjectModel = {
    let bundle = Bundle(for: CoreDataManager.self)
    guard let url = bundle.url(forResource: "flo", withExtension: "momd"),
      let model = NSManagedObjectModel(contentsOf: url)
    else { fatalError("flo.momd is missing from \(bundle.bundlePath)") }
    return model
  }()

  static func inMemoryContainer() -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "flo", managedObjectModel: model)
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
        Thread.sleep(forTimeInterval: 0.5)
      }
    }

    isUsingVolatileStore = true
    return Self.inMemoryContainer()
  }()

  private static func loadPersistentContainer() -> NSPersistentContainer? {
    let container = NSPersistentContainer(name: "flo", managedObjectModel: model)
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
    value: V,
    limit: Int = 0,
    sortDescriptors: [NSSortDescriptor]? = nil
  ) -> [T] {
    let request: NSFetchRequest<T> = NSFetchRequest<T>(entityName: String(describing: T.self))

    guard let predicate = Self.predicate(key, value) else {
      return []
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
      return try self.viewContext.count(for: request)
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
    value: V
  ) {
    guard let predicate = Self.predicate(key, value) else {
      return
    }

    batchDelete(entityName: String(describing: T.self), predicate: predicate)
  }

  /// `key == value`; nil for a key path Core Data cannot name.
  private static func predicate<T: NSManagedObject, V>(_ key: KeyPath<T, V>, _ value: V)
    -> NSPredicate?
  {
    guard let keyPathString = key._kvcKeyPathString, let value = value as? CVarArg else {
      return nil
    }
    return NSPredicate(format: "%K == %@", keyPathString, value)
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
