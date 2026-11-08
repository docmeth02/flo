//
//  DownloadStorage.swift
//  Ownwave
//

import Combine
import Foundation

/// Deletes every download.
class DownloadStorage: ObservableObject {
  static let shared = DownloadStorage()

  func deleteAllDownloads() {
    // A song still downloading would come back.
    DownloadSession.shared.cancelAll()
    LocalFileManager.shared.deleteDownloadedAlbums { result in
      switch result {
      case .success:
        // Records go even when the media folder was already missing.
        CoreDataManager.shared.clearDownloads()
        DownloadSession.shared.downloadsRemoved.send()
      case .failure(let error):
        debugLog("deleteAllDownloads failed: \(error)")
      }
    }
  }
}
