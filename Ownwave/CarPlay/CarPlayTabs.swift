//
//  CarPlayTabs.swift
//  Ownwave
//

import CarPlay
import Combine

// The four tabs and the lists pushed from them.
extension CarPlayController {
  func homeTab() -> TabScreen { tab("Home", "house.fill") }
  func libraryTab() -> TabScreen { tab("Library", "square.stack.fill") }
  func likedTab() -> TabScreen { tab("Liked", "heart.fill") }
  func downloadsTab() -> TabScreen { tab("Downloads", "arrow.down.circle.fill") }

  private func tab(_ title: String, _ symbol: String) -> TabScreen {
    let template = CPListTemplate(title: title, sections: [])
    template.tabTitle = title
    template.tabImage = UIImage(systemName: symbol)
    return TabScreen(template: template, sections: { [] }, changes: Empty().eraseToAnyPublisher())
  }

  func openAlbum(_ album: Album) {}
  func openArtist(_ artist: Artist) {}
  func openPlaylist(_ playlist: Playlist) {}
  func openCached() {}
  func openUpNext() {}
}
