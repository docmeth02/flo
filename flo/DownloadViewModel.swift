//
//  DownloadViewModel.swift
//  flo
//
//  Created by rizaldy on 12/01/25.
//

import Alamofire
import SwiftUI

enum DownloadStatus {
  case idle
  case queued
  case downloading
  case completed
  case failed
  case cancelled
}

struct DownloadItem: Identifiable {
  // Collection and track together: the same song downloaded for an album and
  // for a playlist is two jobs with two destinations.
  let id: String
  let mediaFileId: String
  let albumId: String
  let album: String
  let isPlaylist: Bool
  let title: String
  let song: Song
  let playlistIndex: Int
  var progress: Double = 0
  var status: DownloadStatus = .idle
}

struct DownloadTrackCount: Identifiable {
  let id: String
  let name: String
  var elapsed: Double
  let total: Int
}

class DownloadViewModel: ObservableObject {
  @Published internal(set) var downloadItems: [DownloadItem] = []
  @Published internal(set) var currentDownloads: Set<String> = []
  @Published var downloadedTrackCount: [DownloadTrackCount] = []

  @Published var downloadWatcher: Bool = true

  private var activeDownloads: [String: DownloadRequest] = [:]

  // Collections are identified by id throughout: two albums may share a name.
  func isDownloading(collectionId: String) -> Bool {
    downloadItems.contains { item in
      item.albumId == collectionId
        && (item.status == .downloading || item.status == .queued || item.status == .idle)
    }
  }

  func addItem(_ album: Album, forceAll: Bool = false, isFromPlaylist: Bool = false) {
    let songsToDownload: [(index: Int, song: Song)] = album.songs.enumerated().compactMap {
      index, song in
      forceAll || song.fileUrl.isEmpty ? (index, song) : nil
    }

    let downloadingAlbum = DownloadTrackCount(
      id: album.id, name: album.name, elapsed: 0, total: songsToDownload.count)
    downloadedTrackCount.removeAll { $0.id == album.id }
    downloadedTrackCount.append(downloadingAlbum)

    for (index, song) in songsToDownload {
      let songId = isFromPlaylist ? song.mediaFileId : song.id
      // The collection's id names its download folder and groups its songs.
      let albumId = album.id
      let itemId = "\(albumId):\(songId)"

      guard !downloadItems.contains(where: { $0.id == itemId }) else {
        retryDownload(itemId)

        continue
      }

      let queue = DownloadItem(
        id: itemId, mediaFileId: songId, albumId: albumId, album: album.name,
        isPlaylist: isFromPlaylist,
        title: "\(song.artist) - \(song.title)", song: song,
        playlistIndex: isFromPlaylist ? index : -1)
      downloadItems.append(queue)
    }

    processQueue()
  }

  func processQueue() {
    let maxConcurrentDownloads = ProcessInfo.processInfo.activeProcessorCount / 2
    let downloadedTracks = downloadItems.filter { $0.status == .completed }

    if downloadedTracks.count >= maxConcurrentDownloads * 2 {
      clearCompletedQueue()
    }

    guard currentDownloads.count < maxConcurrentDownloads else { return }

    let availableSlots = maxConcurrentDownloads - currentDownloads.count

    let pendingDownloads =
      downloadItems
      .enumerated()
      .filter { $0.element.status == .idle || $0.element.status == .queued }
      .prefix(availableSlots)

    for (index, _) in pendingDownloads {
      startDownload(index: index)
    }
  }

  func getDownloadedTrackProgress(collectionId: String) -> Double {
    if let index = self.downloadedTrackCount.firstIndex(where: { $0.id == collectionId }) {
      return self.downloadedTrackCount[index].elapsed * 100
    } else {
      return .zero
    }
  }

  private func startDownload(index: Int) {
    var hasPassedThreshold = false

    let item = downloadItems[index]

    guard item.status != .downloading && item.status != .completed else { return }

    currentDownloads.insert(item.id)

    let progressUpdate: (Double) -> Void = { progress in
      self.updateItemProgress(itemId: item.id, progress: progress)

      if let index = self.downloadedTrackCount.firstIndex(where: {
        $0.id == item.albumId
      }) {
        let totalTracks = self.downloadedTrackCount[index].total

        if totalTracks == 1 {
          self.downloadedTrackCount[index].elapsed = progress / 100
        } else {
          if progress >= 100.0 && !hasPassedThreshold {
            hasPassedThreshold = true
            self.downloadedTrackCount[index].elapsed += 1.0 / Double(totalTracks)
          }
        }
      }
    }

    self.updateItemStatus(itemId: item.id, status: DownloadStatus.downloading)

    // The request is created and registered on the main thread before any
    // completion can run, so a fast failure never leaves a stale entry.
    activeDownloads[item.id] = AlbumService.shared.downloadNew(
      collectionId: item.albumId, mediaFileId: item.mediaFileId, suffix: item.song.suffix,
      progressUpdate: progressUpdate
    ) { [weak self] result in
      Task { @MainActor in
        guard let self = self else { return }
        // Every outcome frees the slot; failed items used to keep theirs,
        // and once all slots held failures no download could start.
        defer { self.finishDownload(item.id) }

        switch result {
        case .success(.some):
          AlbumService.shared.saveDownload(
            albumId: item.albumId,
            albumName: item.album,
            song: item.song,
            status: "Downloaded",
            isFromPlaylist: item.isPlaylist,
            playlistIndex: item.playlistIndex
          )
          self.updateItemStatus(itemId: item.id, status: DownloadStatus.completed)
          self.downloadWatcher = true

          if let index = self.downloadedTrackCount.firstIndex(where: {
            $0.id == item.albumId && $0.total == 1
          }) {
            self.downloadedTrackCount.remove(at: index)
          }

        case .success(.none):
          self.updateItemStatus(itemId: item.id, status: .failed)

        case .failure(let error):
          if let afError = error.asAFError, case .explicitlyCancelled = afError {
            self.updateItemStatus(itemId: item.id, status: .cancelled)

            if let index = self.downloadedTrackCount.firstIndex(where: {
              $0.id == item.albumId && $0.total == 1
            }) {
              self.downloadedTrackCount[index].elapsed = 0
            }
          } else {
            print(error)
            self.updateItemStatus(itemId: item.id, status: .failed)
          }
        }
      }
    }
  }

  private func finishDownload(_ itemId: String) {
    currentDownloads.remove(itemId)
    activeDownloads.removeValue(forKey: itemId)
    processQueue()
  }

  func cancelCurrentAlbumDownload(collectionId: String) {
    // Waiting items go first: cancelling the running one schedules the next
    // waiting item, which must not belong to the collection being cancelled.
    for index in downloadItems.indices
    where downloadItems[index].albumId == collectionId
      && (downloadItems[index].status == .idle || downloadItems[index].status == .queued)
    {
      downloadItems[index].status = .cancelled
    }

    downloadItems
      .filter { $0.albumId == collectionId }
      .forEach { cancelDownload($0.id) }
  }

  func cancelDownload(_ itemId: String) {
    if let request = activeDownloads[itemId] {
      request.cancel()

      if let index = downloadItems.firstIndex(where: { $0.id == itemId }) {
        downloadItems[index].status = .cancelled
        downloadItems[index].progress = .zero

        currentDownloads.remove(itemId)
      }

      activeDownloads.removeValue(forKey: itemId)
      self.processQueue()
    }
  }

  func retryDownload(_ itemId: String) {
    if let index = downloadItems.firstIndex(where: { $0.id == itemId }) {
      downloadItems[index].status = .queued
      self.processQueue()
    }
  }

  func clearCompletedQueue() {
    let newDownloadItems = downloadItems.filter {
      $0.status != .completed && $0.status != .cancelled
    }

    downloadItems = newDownloadItems
  }

  private func updateItemProgress(itemId: String, progress: Double) {
    if let index = downloadItems.firstIndex(where: { $0.id == itemId }) {
      downloadItems[index].progress = progress
    }
  }

  private func updateItemStatus(itemId: String, status: DownloadStatus) {
    if let index = downloadItems.firstIndex(where: { $0.id == itemId }) {
      downloadItems[index].status = status
    }
  }
}
