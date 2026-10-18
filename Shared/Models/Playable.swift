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
}

struct SongCollection: Playable {
  let id: String
  let name: String
  var songs: [Song]
  /// Songs taken from a playlist keep it as their origin.
  var isPlaylist = false
}
