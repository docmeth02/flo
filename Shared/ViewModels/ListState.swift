//
//  ListState.swift
//  Ownwave
//

import Foundation

/// Loading and failure of one library list, so a failed album fetch does
/// not show on the playlists.
struct ListState {
  var isLoading = false
  var failed = false
  var loadedAt: Date?
}
