//
//  WatchAlbumsListView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchAlbumsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  @AppStorage(AlbumOrder.storageKey) private var order = AlbumOrder.added
  // The last sort, so a redraw sorts again only when the list or order changed.
  @State private var sort = SortMemo<AlbumOrder>()
  @State private var openedAlbum: Album?
  @State private var menu: MenuTarget?

  var body: some View {
    let albums = sort.sorted(albumViewModel.albums, by: order)
    LibraryList(
      title: "Albums", state: albumViewModel.state(.albums),
      isEmpty: albums.isEmpty,
      empty: .empty(
        systemImage: "square.stack", tint: .floLilac, title: "No albums",
        message: "Albums on your Navidrome server show up here."),
      refresh: albumViewModel.refreshAlbums
    ) {
      SortHeader(count: counted(albums.count, "album"), order: $order)
      PinnedList(items: albums, kind: .album, allLabel: "All Albums") { albums, _ in
        AlbumGrid(albums: albums, menu: $menu) { openedAlbum = $0 }
      }
    }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.fetchAlbums()
    }
  }
}

/// Albums two to a list row, each its cover with the name and artist under
/// it.
private struct AlbumGrid: View {
  let albums: [Album]
  @Binding var menu: MenuTarget?
  let open: (Album) -> Void

  private static let spacing: CGFloat = 8

  var body: some View {
    let pairs = stride(from: 0, to: albums.count, by: 2).map {
      Array(albums[$0..<min($0 + 2, albums.count)])
    }
    ForEach(pairs, id: \.[0].id) { pair in
      HStack(alignment: .top, spacing: Self.spacing) {
        ForEach(pair) { album in
          AlbumTile(album: album, menu: $menu) { open(album) }
        }
        if pair.count == 1 {
          Color.clear.frame(maxWidth: .infinity)
        }
      }
      .padding(.bottom, Self.spacing)
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
    }
  }
}

private struct AlbumTile: View {
  @EnvironmentObject private var pinStore: PinStore

  let album: Album
  @Binding var menu: MenuTarget?
  let open: () -> Void

  private static let coverRadius: CGFloat = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Color.floSkeleton
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          GeometryReader { WatchAlbumArtView(albumId: album.id, size: $0.size.width) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.coverRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if pinStore.isPinned(album.id, .album) {
            PinGlyph()
              .padding(5)
              .background(Circle().fill(Color.floSurface))
              .padding(4)
          }
        }
      VStack(alignment: .leading, spacing: 0) {
        Text(album.name)
          .font(.floRowTitle)
        Text(album.albumArtist)
          .font(.floMeta)
          .foregroundStyle(Color.floSecondary)
      }
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .holdable(onTap: open, onHold: { menu = .album(album) })
  }
}

/// A sortable list's count and order; a tap picks the order on a screen of
/// its own, since the watch has no menus.
struct SortHeader<Order: LibraryOrder & Hashable>: View {
  let count: String
  @Binding var order: Order

  var body: some View {
    NavigationLink {
      ChoiceList(title: "Sort", options: Order.allCases.map { ($0, $0.label) }, selection: $order)
    } label: {
      // Side by side as designed, stacked where a long order does not fit.
      ViewThatFits {
        HStack {
          countLabel
          Spacer(minLength: 4)
          orderLabel
        }
        VStack(alignment: .leading, spacing: 2) {
          countLabel
          orderLabel
        }
      }
      .font(.floRow)
      .lineLimit(1)
    }
    .listRowBackground(Color.clear)
  }

  private var countLabel: some View {
    Text(count).foregroundStyle(Color.floSecondary)
  }

  private var orderLabel: some View {
    HStack(spacing: 3) {
      Text(order.label)
      Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
    }
    .fontWeight(.semibold)
    .foregroundStyle(Color.floLilac)
  }
}

/// A hint in the room under a short list.
struct LibraryHint: View {
  /// From this many rows a list fills the screen and needs no hint.
  static let shortList = 4

  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.floMeta)
      .foregroundStyle(Color.floSecondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
      .listRowBackground(Color.clear)
  }
}

/// A library list: its rows, or the placeholder while it has none, with
/// pull-to-refresh and a refresh button that shows the request under way.
struct LibraryList<Rows: View>: View {
  let title: String
  let state: ListState
  let isEmpty: Bool
  let empty: StateView.Kind
  let refresh: () async -> Void
  @ViewBuilder var rows: Rows

  private var placeholder: StateView.Kind {
    if state.isLoading { return .loading }
    if state.failed { return .error(retry: { Task { await refresh() } }) }
    return empty
  }

  var body: some View {
    Group {
      if isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        // Plain, so rows joined on one platter keep their size at the
        // screen's edges, and as low as their content; at 0 the rows before
        // and in the first section went missing.
        List { rows }
          .listStyle(.plain)
          .environment(\.defaultMinListRowHeight, 1)
      }
    }
    .floNavigationTitle(title)
    .refreshable {
      await refresh()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if state.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
  }
}

/// What a library list shows instead of its rows while it has none: the
/// skeleton rows at the top, a message centered on the screen.
struct LibraryPlaceholder: View {
  let kind: StateView.Kind

  private var isLoading: Bool {
    if case .loading = kind { return true }
    return false
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        StateView(kind: kind)
          .padding(.horizontal, 8)
          .frame(
            maxWidth: .infinity, minHeight: proxy.size.height,
            alignment: isLoading ? .top : .center)
      }
    }
  }
}
