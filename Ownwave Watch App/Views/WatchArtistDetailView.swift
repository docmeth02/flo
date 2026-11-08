//
//  WatchArtistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @Environment(\.showPlayer) private var showPlayer

  @StateObject private var radio = ArtistRadio()
  @State private var isLoadingTopSongs = false
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  private static let glyphSize: CGFloat = 44

  let artist: Artist

  var body: some View {
    let albums = albumViewModel.albums(byArtist: artist.id)
    List {
      header
        .listRowBackground(Color.clear)

      HStack(spacing: 6) {
        Button(action: { radio.start(artist, player: playerViewModel, showPlayer: showPlayer) }) {
          if radio.isLoading {
            ProgressView()
          } else {
            Label("Radio", systemImage: Glyph.radio)
          }
        }
        .accessibilityLabel("Artist Radio")

        // Top songs online, else the artist's songs on the watch, as Siri
        // plays an artist.
        Button(action: {
          Task {
            isLoadingTopSongs = true
            if await playerViewModel.playArtist(id: artist.id, name: artist.name) { showPlayer() }
            isLoadingTopSongs = false
          }
        }) {
          if isLoadingTopSongs {
            ProgressView()
          } else {
            Label {
              Text("Top Songs").minimumScaleFactor(0.8)
            } icon: {
              Image(systemName: "chart.line.uptrend.xyaxis")
            }
          }
        }
      }
      .buttonStyle(TileButtonStyle(alignment: .center))
      .disabled(playerViewModel.isGeneratingMix)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      Section {
        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
          CoverRow(
            tile: .cover(albumId: album.id),
            title: album.name,
            subtitle: album.minYear > 0 ? String(album.minYear) : "",
            tileSize: WatchLayout.smallThumbnail
          )
          .holdable(onTap: { openedAlbum = album }, onHold: { menu = .album(album) })
          .joinedRow(RowPosition(index: index, count: albums.count))
        }
      } header: {
        SectionHeader("Albums")
      }
    }
    .listStyle(.plain)
    // Rows as low as their content, so the joined albums sit tight; 0 made
    // watchOS skip rows.
    .environment(\.defaultMinListRowHeight, 1)
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    // Go to Artist of another album artist's album, such as a compilation.
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu, showing: artist.id, openedArtist: $openedArtist)
    .onAppear {
      albumViewModel.fetchAlbumsByArtist(id: artist.id)
    }
    .artistRadio(radio)
  }

  /// The artist stands in for a navigation title.
  private var header: some View {
    HStack(spacing: WatchLayout.tileSpacing) {
      Image(systemName: Glyph.artist)
        .font(.system(size: 22))
        .foregroundStyle(Dusk.fill)
        .frame(width: Self.glyphSize, height: Self.glyphSize)
        .background(Circle().fill(Dusk.surface2))
      VStack(alignment: .leading, spacing: 1) {
        Text(artist.name)
          .font(.song)
          .lineLimit(2)
        if artist.albumCount > 0 {
          Text(counted(artist.albumCount, "album"))
            .font(.meta)
            .foregroundStyle(Dusk.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Artist Radio started from a screen. It ends with the screen, so a late
/// answer never replaces a queue edited meanwhile, and `.artistRadio(_:)`
/// says why nothing played.
@MainActor final class ArtistRadio: ObservableObject {
  /// Which button spins: the player's `isGeneratingMix` is also set while Top
  /// Songs or Play Something builds.
  @Published private(set) var isLoading = false
  /// The artist whose radio played nothing, and why.
  @Published fileprivate var miss: (name: String, message: String)?
  private var task: Task<Void, Never>?

  func start(_ artist: Artist, player: PlayerViewModel, showPlayer: EnvironmentAction<Void>) {
    task?.cancel()
    task = Task {
      isLoading = true
      let outcome = await player.playArtistRadio(id: artist.id, name: artist.name)
      // A newer start or the screen's end owns the state now.
      guard !Task.isCancelled else { return }
      isLoading = false
      if outcome == .played { showPlayer() }
      miss = outcome.message.map { (artist.name, $0) }
    }
  }

  fileprivate func cancel() {
    task?.cancel()
    isLoading = false
  }
}

extension View {
  /// Ends the screen's Artist Radio with it and shows why one played nothing.
  func artistRadio(_ radio: ArtistRadio) -> some View {
    modifier(ArtistRadioAlert(radio: radio))
  }
}

private struct ArtistRadioAlert: ViewModifier {
  @ObservedObject var radio: ArtistRadio

  func body(content: Content) -> some View {
    content
      .onDisappear { radio.cancel() }
      .alert(
        radio.miss?.name ?? "",
        isPresented: Binding(get: { radio.miss != nil }, set: { if !$0 { radio.miss = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(radio.miss?.message ?? "")
      }
  }
}
