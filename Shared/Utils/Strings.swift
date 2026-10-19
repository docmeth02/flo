//
//  Strings.swift
//  flo
//
//  Created by rizaldy on 09/06/24.
//

import Foundation

extension Double {
  /// "3:45", as track lists and the players show a time in seconds.
  var minuteSecond: String {
    Duration.seconds(isFinite ? max(self, 0) : 0).formatted(.time(pattern: .minuteSecond))
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
