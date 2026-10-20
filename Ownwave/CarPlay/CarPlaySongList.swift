//
//  CarPlaySongList.swift
//  Ownwave
//

import CarPlay

/// A pushed list of songs.
@MainActor final class SongListScreen {
  let template: CPListTemplate

  init(title: String) {
    template = CPListTemplate(title: title, sections: [])
  }
}
