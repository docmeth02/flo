//
//  WidgetSnapshot.swift
//  Ownwave
//

import Foundation

/// What the widgets show, written by the app into the App Group container
/// and read by the extension, which has no access to the app's own data.
struct WidgetSnapshot: Codable, Equatable {
  struct Song: Codable, Equatable {
    let title: String
    let artist: String
    let albumId: String
  }

  struct Album: Codable, Equatable, Identifiable {
    let id: String
    let name: String
  }

  var signedIn = false
  var nowPlaying: Song?
  /// The four albums played last.
  var recent: [Album] = []

  static let appGroup = "group.de.m2-entertainment.ownwave"

  /// The widget kinds, one per widget, reloaded on their own.
  enum Kind {
    static let playSomething = "PlaySomething"
    static let nowPlaying = "NowPlaying"
    static let recentlyPlayed = "RecentlyPlayed"
    static let launcher = "Launcher"
  }

  /// Deep links into the app.
  enum Link {
    static let nowPlaying = URL(string: "ownwave://nowplaying")!
    static let home = URL(string: "ownwave://")!

    static func album(_ id: String) -> URL {
      URL(string: "ownwave://album/\(id)")!
    }
  }

  static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  private static var fileURL: URL? { container?.appendingPathComponent("snapshot.json") }

  /// Covers as small JPEGs beside the snapshot.
  static var coversFolder: URL? { container?.appendingPathComponent("covers", isDirectory: true) }

  static func coverURL(albumId: String) -> URL? {
    coversFolder?.appendingPathComponent("\(albumId).jpg")
  }

  static func load() -> WidgetSnapshot {
    guard let url = fileURL, let data = try? Data(contentsOf: url),
      let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    else { return WidgetSnapshot() }
    return snapshot
  }

  func save() {
    guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
