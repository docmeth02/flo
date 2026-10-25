//
//  ServerAccount.swift
//  flo
//

import Foundation

/// The signed-in server and user, as Settings and Server show them.
enum ServerAccount {
  /// The server without its scheme, e.g. "music.home.lan" or
  /// "example.com/navidrome".
  static var host: String { authority + path }

  /// "music.home.lan:4533": the host and port, without the user or scheme.
  static var authority: String { authority(of: UserDefaultsManager.serverBaseURL) }

  /// "/navidrome", empty for a server at the root of its host.
  static var path: String { path(of: UserDefaultsManager.serverBaseURL) }

  /// The whole address when it does not parse.
  static func authority(of url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host else {
      return url
    }
    return host + (components.port.map { ":\($0)" } ?? "")
  }

  static func path(of url: String) -> String {
    guard let components = URLComponents(string: url), components.host != nil,
      components.path != "/"
    else { return "" }
    return components.path
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
