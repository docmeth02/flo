//
//  WatchArtistDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchArtistDetailView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @Environment(\.showPlayer) private var showPlayer

  @StateObject var artistDetailViewModel = ArtistDetailViewModel()

  @State private var displayAlert: Bool = false
  @State private var radioFailed = false
  /// Ends with the screen, so a late answer never replaces a newer queue.
  @State private var radioTask: Task<Void, Never>?
  @State private var isLoadingTopSongs = false
  @State private var openedAlbum: Album?
  @State private var menu: MenuTarget?

  private static let glyphSize: CGFloat = 44

  let artist: Artist

  var body: some View {
    let albums = albumViewModel.albums(byArtist: artist.id)
    List {
      header
        .listRowBackground(Color.clear)

      HStack(spacing: 6) {
        Button(action: {
          radioTask = Task {
            let songs = await artistDetailViewModel.fetchArtistRadio(artist: artist)
            guard !Task.isCancelled else { return }
            if let songs, !songs.isEmpty {
              let radio = SongCollection.artistRadio(id: artist.id, name: artist.name, songs: songs)
              if playerViewModel.playItem(item: radio) { showPlayer() }
            } else {
              radioFailed = songs == nil
              displayAlert = true
            }
          }
        }) {
          if artistDetailViewModel.isLoadingRadio {
            ProgressView()
          } else {
            Label("Radio", systemImage: CoverTile.radioGlyph)
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
      .buttonStyle(FloTileButtonStyle(alignment: .center))
      .disabled(artistDetailViewModel.isLoadingRadio || playerViewModel.isGeneratingMix)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      Section {
        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
          CoverRow(
            tile: .cover(albumId: album.id),
            title: album.name,
            subtitle: album.minYear > 0 ? String(album.minYear) : "",
            tileSize: FloLayout.smallThumbnail
          )
          .holdable(onTap: { openedAlbum = album }, onHold: { menu = .album(album) })
          .floJoinedRow(RowPosition(index: index, count: albums.count))
        }
      } header: {
        FloSectionHeader("Albums")
      }
    }
    .listStyle(.plain)
    // Rows as low as their content, so the joined albums sit tight; 0 made
    // watchOS skip rows.
    .environment(\.defaultMinListRowHeight, 1)
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .itemMenu($menu)
    .onAppear {
      albumViewModel.fetchAlbumsByArtist(id: artist.id)
    }
    .onDisappear { radioTask?.cancel() }
    .alert(artist.name, isPresented: $displayAlert) {
      Button("OK") {}
    } message: {
      Text(ArtistDetailViewModel.noRadioMessage(failed: radioFailed))
    }
  }

  /// The artist stands in for a navigation title.
  private var header: some View {
    HStack(spacing: FloLayout.tileSpacing) {
      Image(systemName: "music.mic")
        .font(.system(size: 22))
        .foregroundStyle(Color.floLilac)
        .frame(width: Self.glyphSize, height: Self.glyphSize)
        .background(Circle().fill(Color.floSurface2))
      VStack(alignment: .leading, spacing: 1) {
        Text(artist.name)
          .font(.floSong)
          .lineLimit(2)
        if artist.albumCount > 0 {
          Text(counted(artist.albumCount, "album"))
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}
