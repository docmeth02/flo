//
//  WatchDiagnosticsView.swift
//  flo Watch App
//

import SwiftUI

/// Connection state, the history import, the latest mix and server requests,
/// to tell a slow or broken server from an app problem on the device itself.
/// Shows no secrets, and neither does the shared log.
struct WatchDiagnosticsView: View {
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @ObservedObject private var log = RequestLog.shared
  @ObservedObject private var history = HistoryStatus.shared
  @ObservedObject private var ratings = RatingStore.shared
  @ObservedObject private var recommendations = RecommendationLog.shared

  var body: some View {
    List {
      Section {
        ShareLink(item: Self.exportText(), subject: Text("flo watch log")) {
          Label("Share log", systemImage: "square.and.arrow.up")
            .font(.floRow)
            .foregroundStyle(Color.floLavender)
        }
        .floRow()
      }

      Section {
        ForEach(Self.connectionLines(), id: \.0) { row($0.0, $0.1) }
      }

      Section {
        ForEach(Self.historyLines(history.state), id: \.0) { row($0.0, $0.1) }
      } header: {
        FloSectionHeader("History")
      }

      Section {
        if let mix = recommendations.mixes.first {
          Text(Self.summary(of: mix))
            .font(.floMeta)
            .floRow()
          ForEach(Array(mix.picks.enumerated()), id: \.offset) { _, pick in
            row("\(pick.slot) · \(pick.reason)", "\(pick.title) — \(pick.artist)")
          }
        } else {
          Text("No mix yet")
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .floRow()
        }
      } header: {
        FloSectionHeader("Last mix")
      }

      Section {
        ForEach(log.entries) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
              .font(.caption2)
              .foregroundStyle(Color.floSecondary)
              .lineLimit(2)
            Text(details(of: entry))
              .font(.floMeta)
              .foregroundStyle(entry.isFailure ? Color.floDestructive : .white)
              .lineLimit(2)
          }
          .floRow()
        }
      } header: {
        FloSectionHeader("Requests")
      }
    }
    .navigationTitle("Diagnostics")
    .task { await ListeningHistoryStore.shared.publishStoredState() }
  }

  private static func connectionLines() -> [(String, String)] {
    let connectivity = ConnectivityMonitor.shared
    return [
      ("Online", connectivity.isOnline ? "Yes" : "No"),
      ("Server reachable", connectivity.isServerReachable ? "Yes" : "No"),
      ("Token expires", tokenExpiry),
    ]
  }

  private static func historyLines(_ state: ImportState) -> [(String, String)] {
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

  private static func summary(of mix: MixRecord) -> String {
    "\(mix.mode) · \(mix.picks.count) picks · explore \(Int((mix.exploreShare * 100).rounded())) %"
  }

  /// The diagnostics as plain text with the request log newest first.
  /// Main thread only.
  static func exportText() -> String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    var lines = [
      "flo watch \(version) (\(build)), \(Date().formatted(.iso8601))"
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
          + "status=\(entry.status.map(String.init) ?? "-") error=\(entry.error ?? "-")")
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

  private func row(_ title: String, _ value: String) -> some View {
    FloInfoRow(title, value).floRow()
  }

  private func details(of entry: RequestLog.Entry) -> String {
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
