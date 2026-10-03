//
//  RequestLog.swift
//  flo
//

import Alamofire
import Foundation

/// The latest server requests and connectivity verdicts, for the diagnostics
/// screen. Records paths only, never queries: Subsonic credentials live there.
final class RequestLog: ObservableObject {
  static let shared = RequestLog()

  struct Entry: Identifiable {
    let id = UUID()
    /// Seconds since launch.
    let startedAt: TimeInterval
    /// e.g. "GET /api/album" or "rest getStarred2".
    let text: String
    let status: Int?
    let error: String?
    let duration: TimeInterval?
    let bytes: Int64
    let retries: Int

    var isFailure: Bool {
      error != nil || status.map { !(200..<300).contains($0) } ?? false
    }
  }

  let launchDate = Date()
  let monitor = Monitor()
  /// Newest first. Main thread only.
  @Published private(set) var entries: [Entry] = []

  private let maxEntries = 80

  private init() {}

  func note(_ text: String) {
    add(
      Entry(
        startedAt: Date().timeIntervalSince(launchDate), text: text, status: nil, error: nil,
        duration: nil, bytes: 0, retries: 0))
  }

  func clear() {
    DispatchQueue.main.async { self.entries.removeAll() }
  }

  private func add(_ entry: Entry) {
    DispatchQueue.main.async {
      self.entries.insert(entry, at: 0)
      if self.entries.count > self.maxEntries { self.entries.removeLast() }
    }
  }

  /// Logs every attempt, so a request retried after a 401 shows up twice.
  final class Monitor: EventMonitor {
    let queue = DispatchQueue(label: "flo.requestlog")
    // Task creation times, in case a task delivers no metrics.
    private var createdAt: [ObjectIdentifier: Date] = [:]

    func request(_ request: Request, didCreateTask task: URLSessionTask) {
      createdAt[ObjectIdentifier(task)] = Date()
    }

    func request(_ request: Request, didCompleteTask task: URLSessionTask, with error: AFError?) {
      let log = RequestLog.shared
      let created = createdAt.removeValue(forKey: ObjectIdentifier(task))
      // Runs on its own queue, so the request may already be on its next
      // attempt; tasks and metrics are kept in order.
      let attempt = request.tasks.firstIndex(of: task) ?? request.retryCount
      let metrics = request.allMetrics.indices.contains(attempt) ? request.allMetrics[attempt] : nil
      let interval = metrics?.taskInterval
      let start = interval?.start ?? created ?? Date()

      log.add(
        Entry(
          startedAt: start.timeIntervalSince(log.launchDate),
          text: Self.describe(task.originalRequest),
          status: (task.response as? HTTPURLResponse)?.statusCode,
          error: error.map(Self.shortText),
          duration: interval?.duration ?? created.map { Date().timeIntervalSince($0) },
          bytes: task.countOfBytesReceived,
          retries: attempt))
    }

    private static func describe(_ request: URLRequest?) -> String {
      guard let url = request?.url else { return "?" }
      let path = url.path
      if let range = path.range(of: "/rest/") {
        let method = path[range.upperBound...]
        return "rest " + (method.hasSuffix(".view") ? String(method.dropLast(5)) : String(method))
      }
      return "\(request?.httpMethod ?? "GET") \(path)"
    }

    private static func shortText(_ error: AFError) -> String {
      let text = error.underlyingError?.localizedDescription ?? error.localizedDescription
      return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
  }
}
