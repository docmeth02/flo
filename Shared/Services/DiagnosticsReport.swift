//
//  DiagnosticsReport.swift
//  Ownwave
//

import Foundation

/// What both apps' Diagnostics show and share: connection state, the history
/// import, the latest mixes and server requests. Shows no secrets, and
/// neither does the shared log.
@MainActor
enum DiagnosticsReport {
  /// The model identifier, e.g. "Watch6,18" or "iPhone18,1".
  static var hardwareModel: String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  static func connectionLines() -> [(String, String)] {
    let connectivity = ConnectivityMonitor.shared
    return [
      ("Online", connectivity.isOnline ? "Yes" : "No"),
      ("Server reachable", connectivity.isServerReachable ? "Yes" : "No"),
      ("Token expires", tokenExpiry),
    ]
  }

  static func historyLines(_ state: ImportState) -> [(String, String)] {
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    relative.dateTimeStyle = .named

    // A partial total would read as the server's whole history.
    var plays = state.importedCount == 0 ? "not imported" : "incomplete"
    if case .importing = state.phase { plays = "importing" }
    if state.bootstrapComplete {
      plays = "\(state.serverTotal) plays"
      if let earliest = state.earliestPlayAt {
        plays += ", earliest \(earliest.formatted(date: .abbreviated, time: .omitted))"
      }
    }

    var status: String
    switch state.phase {
    case .idle: status = state.bootstrapComplete ? "complete" : "waiting"
    case .importing(let page): status = "importing (page \(page))"
    case .complete: status = "complete"
    case .failed(let reason): status = "failed \(reason)"
    case .skipped(let reason): status = "skipped, \(reason)"
    }
    if let last = state.lastImportAt {
      status += ", refreshed \(relative.localizedString(for: last, relativeTo: Date()))"
    }

    return [
      ("Server history", plays),
      ("Matched to library", String(state.matchedCount)),
      ("Import", status),
      ("Pending submissions", String(ScrobbleQueueManager.shared.pendingCount)),
      ("Unmatched", String(state.unmatchedCount)),
      ("Rated songs", String(RatingStore.shared.ratings.count)),
    ]
  }

  static func summary(of mix: MixRecord) -> String {
    "\(mix.mode) · \(mix.picks.count) picks · explore \(Int((mix.exploreShare * 100).rounded())) %"
  }

  /// "200 · 1.2 MB · 0.4 s · +12.3 s", or the error instead of the status.
  static func details(of entry: RequestLog.Entry) -> String {
    var parts: [String] = []
    if let error = entry.error {
      parts.append(error)
    } else if let status = entry.status {
      parts.append(String(status))
    }
    if entry.bytes > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
    }
    if let duration = entry.duration {
      parts.append(String(format: "%.1f s", duration))
    }
    if entry.retries > 0 {
      parts.append("retry \(entry.retries)")
    }
    parts.append(String(format: "+%.1f s", entry.startedAt))
    return parts.joined(separator: " · ")
  }

  /// The report as plain text with the request log newest first.
  static func text() -> String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    var lines = [
      "Ownwave \(version) (\(build)), \(Date().formatted(.iso8601))",
      "\(AppPlatform.systemDescription), \(hardwareModel)",
    ]
    lines += connectionLines().map { "\($0.0): \($0.1)" }
    lines.append("")
    lines.append("History")
    lines += historyLines(HistoryStatus.shared.state).map { "\($0.0): \($0.1)" }
    lines.append("")
    lines.append("Requests, newest first")
    for entry in RequestLog.shared.entries {
      lines.append(
        "  \(String(format: "%.1f", entry.startedAt)) \(entry.text) "
          + "status=\(entry.status.map(String.init) ?? "-") error=\(entry.error ?? "-")"
          + (entry.duration.map { String(format: " %.1fs", $0) } ?? "")
          + (entry.bytes > 0 ? " \(entry.bytes)B" : "")
          + (entry.retries > 0 ? " retry=\(entry.retries)" : ""))
    }
    lines.append("")
    lines.append("Last mixes")
    for mix in RecommendationLog.shared.mixes.prefix(3) {
      lines.append(
        "  \(mix.at.formatted(.iso8601)) \(summary(of: mix)), \(mix.eligible) eligible")
      lines += mix.notes.map { "    \($0)" }
      lines += mix.picks.map {
        "    \($0.slot) \($0.title) — \($0.artist) | \($0.reason) | \($0.scores)"
      }
    }
    return lines.joined(separator: "\n")
  }

  /// The `exp` claim of the Navidrome JWT, relative to now.
  private static var tokenExpiry: String {
    let segments = AuthService.shared.sessionSnapshot().ndToken.split(separator: ".")
    guard segments.count == 3 else { return "none" }
    var payload = segments[1].replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = (claims["exp"] as? NSNumber)?.doubleValue
    else { return "none" }

    let expiry = Date(timeIntervalSince1970: exp)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    let relative = formatter.localizedString(for: expiry, relativeTo: Date())
    return expiry < Date() ? "expired \(relative)" : relative
  }
}
