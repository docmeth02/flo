//
//  Strings.swift
//  Ownwave
//

import Foundation

extension Double {
  /// "3:45", as track lists and the players show a time in seconds.
  var minuteSecond: String {
    Duration.seconds(isFinite ? max(self, 0) : 0).formatted(.time(pattern: .minuteSecond))
  }
}

extension Int64 {
  /// "1.4 GB", a size on disk.
  var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension String {
  /// Songs neither on the device nor reachable on the server.
  static let notAvailableOffline = "Not available offline"
  /// The phone while `TranscodingSettings.streamingBitRate` is nil.
  static let streamingBlocked = "Streaming on cellular is off"

  /// The string cut to at most `length` characters, the last one an ellipsis.
  func truncated(to length: Int) -> String {
    count > length ? String(prefix(length - 1)) + "…" : self
  }
}

/// "12 songs · 48 min", the count alone without a length.
func songsAndLength(_ songs: Int, seconds: Double) -> String {
  let count = counted(songs, "song")
  return seconds.isFinite && seconds > 0
    ? "\(count) · \(Int((seconds / 60).rounded())) min" : count
}

extension [Song] {
  /// "12 songs · 48 min", empty while no song is loaded.
  var countAndLength: String {
    guard !isEmpty else { return "" }
    return songsAndLength(
      count, seconds: reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) })
  }
}

extension Playlist {
  /// "Playlist · 3 songs · 16 min" for its screen, from the server's counts
  /// until `songs` are loaded.
  func meta(loaded songs: [Song]) -> String {
    var length = songs.countAndLength
    if length.isEmpty, songCount > 0 {
      length = songsAndLength(songCount, seconds: duration)
    }
    return length.isEmpty ? "Playlist" : "Playlist · " + length
  }
}
