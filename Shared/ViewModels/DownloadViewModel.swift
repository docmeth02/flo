//
//  DownloadViewModel.swift
//  flo
//
//  Created by rizaldy on 12/01/25.
//

import Combine
import SwiftUI

/// The views' window on `DownloadSession`, which does the downloading.
class DownloadViewModel: ObservableObject {
  private let downloads = DownloadSession.shared
  private var changes: AnyCancellable?

  /// Sent with the collection's id when one of its songs finished downloading.
  var downloadFinished: PassthroughSubject<String, Never> { downloads.downloadFinished }

  init() {
    changes = downloads.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }

  // Collections are identified by id throughout: two albums may share a name.
  func isDownloading(collectionId: String) -> Bool {
    downloads.isDownloading(collectionId: collectionId)
  }

  /// A song of the collection failed for good; downloading it again retries.
  func hasFailed(collectionId: String) -> Bool {
    downloads.hasFailed(collectionId: collectionId)
  }

  func addItem(_ album: Album, isFromPlaylist: Bool = false) {
    downloads.enqueue(album, isPlaylist: isFromPlaylist)
  }

  /// Finished songs in percent.
  func getDownloadedTrackProgress(collectionId: String) -> Double {
    downloads.progress(collectionId: collectionId) * 100
  }

  func cancelCurrentAlbumDownload(collectionId: String) {
    downloads.cancel(collectionId: collectionId)
  }
}
