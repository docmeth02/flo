//
//  Playable.swift
//  flo
//
//  Created by rizaldy on 16/11/24.
//

protocol Playable {
  var id: String { get }
  var name: String { get }
  var songs: [Song] { get set }
  /// Its songs keep the playlist as their origin.
  var isPlaylist: Bool { get }
}

struct SongCollection: Playable {
  let id: String
  let name: String
  var songs: [Song]
  var isPlaylist = false
}
