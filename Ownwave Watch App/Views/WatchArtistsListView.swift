//
//  WatchArtistsListView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchArtistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @AppStorage(ArtistOrder.storageKey) private var order = ArtistOrder.name
  // The last sort and letters, so a redraw sorts and groups again only when
  // the list or order changed.
  @State private var sort = SortMemo<ArtistOrder>()
  @State private var sections = Memo<[Artist], [ArtistSection]>()
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  var body: some View {
    let artists = sort.sorted(albumViewModel.artists, by: order)
    LibraryList(
      title: "Artists", state: albumViewModel.state(.artists),
      isEmpty: artists.isEmpty,
      empty: .empty(
        systemImage: "music.mic", tint: .floLilac, title: "No artists",
        message: "Artists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshArtists
    ) {
      SortHeader(count: counted(artists.count, "artist"), order: $order)
      // By name the letters are the crown's landmarks; by album count they
      // would only interrupt.
      PinnedList(
        items: artists, kind: .artist, allLabel: order == .name ? nil : "All Artists"
      ) { artists, isPinnedPart in
        if order == .name, !isPinnedPart {
          ForEach(sections.value(for: artists, make: artistSections)) { section in
            Section {
              rows(section.artists)
            } header: {
              FloSectionHeader(section.letter)
            }
          }
        } else {
          rows(artists)
        }
      }
    }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.getArtists()
    }
  }

  private func rows(_ artists: [Artist]) -> some View {
    JoinedRows(items: artists) { artist in
      LibraryRow(target: .artist(artist), menu: $menu) { openedArtist = artist }
    }
  }
}
