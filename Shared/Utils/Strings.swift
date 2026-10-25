//
//  Strings.swift
//  flo
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

func bytesToMBOrGB(_ bytes: Int64) -> String {
  let gigabyte: Int64 = 1024 * 1024 * 1024
  let megabyte: Int64 = 1024 * 1024

  if bytes >= gigabyte {
    let gb = Double(bytes) / Double(gigabyte)

    return String(format: "%.0f GB", gb)
  } else {
    let mb = Double(bytes) / Double(megabyte)

    return String(format: "%.0f MB", mb)
  }
}
