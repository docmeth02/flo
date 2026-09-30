//
//  CoreDataManager.swift
//  flo
//
//  Created by rizaldy on 29/06/24.
//

@preconcurrency import CoreData
import Foundation

class CoreDataManager: ObservableObject {
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
        print("Failed to create in-memory store: \(error.localizedDescription)")
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
      if attempt == 1 { Thread.sleep(forTimeInterval: 0.5) }
    }

    isUsingVolatileStore = true
    return Self.inMemoryContainer()
  }()

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
      print("failed to load persistent stores: \(loadError.localizedDescription)")
      return nil
    }

    container.viewContext.automaticallyMergesChangesFromParent = true

    return container
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

  func saveRecord() {
    do {
      try self.viewContext.save()
    } catch {
      self.viewContext.rollback()

      print(error.localizedDescription)
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

    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    deleteRequest.resultType = .resultTypeObjectIDs

    do {
      let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult
      let deletedIDs = result?.result as? [NSManagedObjectID] ?? []
      NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSDeletedObjectsKey: deletedIDs], into: [viewContext])
    } catch {
      print("Failed to delete \(entityName) records: \(error.localizedDescription)")
    }
  }
}
