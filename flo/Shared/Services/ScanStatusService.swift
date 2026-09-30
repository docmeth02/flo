//
//  ScanStatusService.swift
//  flo
//
//  Created by rizaldy on 14/06/24.
//

import Foundation

class ScanStatusService {
  static let shared = ScanStatusService()

  func getDownloadedAlbumsCount() -> Int {
    return CoreDataManager.shared.countRecords(entity: PlaylistEntity.self)
  }

  func getDownloadedSongsCount() -> Int {
    return CoreDataManager.shared.countRecords(entity: SongEntity.self)
  }

}
