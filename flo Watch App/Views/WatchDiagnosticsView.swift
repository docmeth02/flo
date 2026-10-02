//
//  WatchDiagnosticsView.swift
//  flo Watch App
//

import SwiftUI

/// Connection state and the latest server requests, to tell a slow or broken
/// server from an app problem on the device itself. Shows no secrets.
struct WatchDiagnosticsView: View {
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @ObservedObject private var log = RequestLog.shared

  var body: some View {
    List {
      Section {
        row("Online", connectivity.isOnline ? "Yes" : "No")
        row("Server reachable", connectivity.isServerReachable ? "Yes" : "No")
        row("Token expires", tokenExpiry)
      }

      Section("Requests") {
        ForEach(log.entries) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
              .customFont(.caption2)
              .foregroundColor(.secondary)
              .lineLimit(2)
            Text(details(of: entry))
              .customFont(.caption1)
              .foregroundColor(entry.isFailure ? .red : nil)
              .lineLimit(2)
          }
        }
      }
    }
    .navigationTitle("Diagnostics")
  }

  private func row(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .customFont(.caption2)
        .foregroundColor(.secondary)
      Text(value)
        .customFont(.caption1)
    }
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
  private var tokenExpiry: String {
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
