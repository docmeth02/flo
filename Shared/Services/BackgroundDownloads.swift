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

  /// A Subsonic error comes as JSON or XML; an SVG cover is XML too, but an
  /// image.
  static func isErrorBody(_ response: HTTPURLResponse?) -> Bool {
    guard let type = response?.mimeType, !type.hasPrefix("image/") else { return false }
    return type.contains("json") || type.contains("xml")
  }

  /// The code of a Subsonic JSON error body, nil when it cannot be read.
  static func subsonicCode(in file: URL) -> Int? {
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
