//
//  Timeout.swift
//  flo
//

import Foundation

/// What `operation` returns, or nil when `limit` passes first; the operation
/// goes on either way. A task group would wait for it as well, so a stream
/// ends the wait at whichever finishes first.
func withTimeout<T>(_ limit: Duration, _ operation: @escaping () async -> T) async -> T? {
  let (results, deliver) = AsyncStream<T?>.makeStream()
  Task { deliver.yield(await operation()) }
  Task {
    try? await Task.sleep(for: limit)
    deliver.yield(nil)
  }
  for await result in results { return result }
  return nil
}
