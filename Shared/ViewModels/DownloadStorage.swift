//
//  DownloadStorage.swift
//  Ownwave
//

import Combine
import Foundation

/// The size of the downloads folder for Settings and the Downloads list, and
/// deleting every download.
class DownloadStorage: ObservableObject {
  @Published var localDirectorySize: String = "0 MB"

  static let shared = DownloadStorage()

  func refresh() {
    Task {
      let directorySize = await LocalFileManager.shared.calculateDirectorySize()

      await MainActor.run {
        self.localDirectorySize = directorySize
      }
    }
  }

  func deleteAllDownloads() {
    // A song still downloading would come back.
    DownloadSession.shared.cancelAll()
    LocalFileManager.shared.deleteDownloadedAlbums { result in
      switch result {
      case .success:
        // Records go even when the media folder was already missing.
        CoreDataManager.shared.clearDownloads()
        DownloadSession.shared.downloadsRemoved.send()

        self.refresh()

      case .failure(let error):
        debugLog("deleteAllDownloads failed: \(error)")
      }
    }
  }
}
