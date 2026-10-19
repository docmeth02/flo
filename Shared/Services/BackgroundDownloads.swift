//
//  BackgroundDownloads.swift
//  Ownwave
//

import Foundation

// What the background download sessions share: the device's downloads
// (`DownloadSession`) and the phone's songs on their way to the watch
// (`WatchSend`).

/// How a failed download goes on.
enum DownloadFailure: Equatable {
  /// The connection broke or the system cancelled the task (a force-quit):
  /// tried again without counting, so a dead zone never uses up the retries.
  case connection
  /// The server or the transfer failed (5xx, a Subsonic error, a certificate).
  case counted
  /// Retrying cannot help: the server refused the credentials.
  case final

  /// For a task that ended with a URL loading error.
  static func classify(error: Error) -> DownloadFailure {
    // A handshake cut by a dropping link is no server fault; certificate
    // errors still count.
    let code = (error as? URLError)?.code
    if ConnectivityMonitor.isConnectionError(error) || code == .cancelled
      || code == .secureConnectionFailed
    {
      return .connection
    }
    return .counted
  }

  /// For a task that delivered a file; nil when the file is the song. A
  /// Subsonic error arrives with status 200 as a JSON or XML body
  /// (`isErrorBody`), whose code is nil when it could not be read.
  static func classify(status: Int, isErrorBody: Bool, subsonicCode: Int?, bytes: Int64)
    -> DownloadFailure?
  {
    if subsonicCode == 40 { return .final }
    if isErrorBody || !(200..<300).contains(status) || bytes == 0 { return .counted }
    return nil
  }

  /// The verdict on a delivered file and the Subsonic error code its body
  /// carries, if it is one.
  static func check(_ response: HTTPURLResponse?, file: URL?, bytes: Int64)
    -> (failure: DownloadFailure?, subsonicCode: Int?)
  {
    let isErrorBody = isErrorBody(response)
    let code = isErrorBody ? file.flatMap(subsonicCode(in:)) : nil
    let failure = classify(
      status: response?.statusCode ?? 0, isErrorBody: isErrorBody, subsonicCode: code,
      bytes: bytes)
    return (failure, code)
  }

  /// A Subsonic error comes as JSON or XML; an SVG cover is XML too, but an
  /// image.
  private static func isErrorBody(_ response: HTTPURLResponse?) -> Bool {
    guard let type = response?.mimeType, !type.hasPrefix("image/") else { return false }
    return type.contains("json") || type.contains("xml")
  }

  /// The code of a Subsonic JSON error body, nil when it cannot be read.
  private static func subsonicCode(in file: URL) -> Int? {
    (try? JSONDecoder().decode(SubsonicEnvelope<BasicResponse>.self, from: Data(contentsOf: file)))?
      .subsonicResponse.error?.code
  }
}

/// The waits before the retries of a failure that counts.
enum DownloadRetry {
  static let delays: [TimeInterval] = [30, 120, 300]

  /// The wait before the next retry, nil once all are spent and the job fails.
  static func delay(afterAttempts attempts: Int) -> TimeInterval? {
    delays.indices.contains(attempts) ? delays[attempts] : nil
  }
}

/// The jobs of a session on disk, so downloads outlive the process. A
/// background launch may come while the device is locked, so the file stays
/// readable then.
struct JobFile<Job: Codable> {
  let fileURL: URL
  /// What the jobs are, for the log.
  let label: String

  func load() -> [Job] {
    do {
      return try JSONDecoder().decode([Job].self, from: Data(contentsOf: fileURL))
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      RequestLog.shared.note("\(label) unreadable: \(error)")
      return []
    }
  }

  func save(_ jobs: [Job]) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(jobs).write(
        to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      RequestLog.shared.note("\(label) not saved: \(error)")
    }
  }
}

extension URLSession {
  /// A session that transfers while the app is suspended or was ended by the
  /// system, which relaunches the app in the background to hand the files
  /// over. It delegates on the main queue.
  static func background(identifier: String, delegate: URLSessionDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    // Two transcodes over the phone link would halve each other's rate, and
    // the player's stream must not starve.
    configuration.httpMaximumConnectionsPerHost = 1
    // A background task otherwise waits up to 7 days and never fails.
    configuration.timeoutIntervalForResource = 2 * 3600
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
  }
}

/// Keeps the system's wake-ups for a background session until the session
/// has delivered its events. They may also have come before the wake-up (the
/// session exists from launch), so a deadline completes each in any case.
/// Main thread only.
final class BackgroundEventCompletions {
  private var completions: [UUID: () -> Void] = [:]

  func hold(_ completion: @escaping () -> Void) {
    let id = UUID()
    completions[id] = completion
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      self.completions.removeValue(forKey: id)?()
    }
  }

  /// The session delivered its events.
  func complete() {
    let held = completions.values
    completions = [:]
    held.forEach { $0() }
  }
}
