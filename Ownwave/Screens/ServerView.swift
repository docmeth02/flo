//
//  ServerView.swift
//  Ownwave
//

import SwiftUI

/// The server and account behind Settings' server row, with Sign Out.
struct ServerView: View {
  @EnvironmentObject private var auth: AuthViewModel
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @Environment(\.palette) private var palette

  @State private var username = ""
  @State private var version: String?
  @State private var confirmsLogout = false

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        PageTitle("Server")
        SettingsGroup(separatorInset: 0) {
          detail("Address") {
            Text(UserDefaultsManager.serverBaseURL).truncationMode(.middle)
          }
          detail("User") { Text(username) }
          detail("Version") { Text(ServerAccount.product(version: version)) }
          detail("Status") {
            HStack(spacing: 6) {
              StatusDot(isOn: connectivity.isServerReachable)
              Text(connectivity.isServerReachable ? "Reachable" : "Not reachable")
            }
          }
        }
        SettingsGroup {
          Button("Sign Out", role: .destructive) { confirmsLogout = true }
            .font(.rowTitle.weight(.semibold))
            .foregroundStyle(Color.floDestructive)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { username = ServerAccount.username }
    .task { version = await ServerAccount.version() }
    .alert("Sign Out?", isPresented: $confirmsLogout) {
      Button("Cancel", role: .cancel) {}
      Button("Sign Out", role: .destructive) { auth.logout() }
    } message: {
      Text("You will need to sign in again. Downloads stay on this iPhone.")
    }
  }

  private func detail(_ title: String, @ViewBuilder value: () -> some View) -> some View {
    HStack(spacing: 12) {
      Text(title)
      Spacer(minLength: 8)
      value().foregroundStyle(palette.secondary).lineLimit(1)
    }
    .frame(minHeight: 50)
  }
}

/// The signed-in server and user, as Settings and Server show them.
enum ServerAccount {
  /// The server without its scheme, e.g. "music.home.lan" or
  /// "example.com/navidrome".
  static var host: String {
    let url = UserDefaultsManager.serverBaseURL
    guard let components = URLComponents(string: url), let host = components.host else {
      return url
    }
    return host + (components.port.map { ":\($0)" } ?? "") + components.path
  }

  static var username: String {
    if case .found(let login) = KeychainManager.loadAuth() { login.username } else { "" }
  }

  /// "0.64.2" from the server's ping; nil when it did not answer.
  static func version() async -> String? {
    // Navidrome appends its build, "0.64.2 (10114574)".
    await LibraryAPI.serverVersion()?.split(separator: " ").first.map(String.init)
  }

  /// "Navidrome 0.64.2", or just "Navidrome" while the version is unknown.
  static func product(version: String?) -> String {
    version.map { "Navidrome \($0)" } ?? "Navidrome"
  }

  /// "Navidrome 0.64.2 · anna"
  static func line(version: String?, username: String) -> String {
    let name = product(version: version)
    return username.isEmpty ? name : "\(name) · \(username)"
  }
}
