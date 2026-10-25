//
//  WatchDownloadsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchDownloadsView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloads: DownloadSession
  @ObservedObject private var phone = PhoneLink.shared

  @State private var cachedSongs: [Song] = []
  /// Songs on the watch per album, counted when the list or an album changes.
  @State private var songCounts: [String: Int] = [:]
  @State private var storage = StorageUsage()
  @State private var storageChanges = 0

  var body: some View {
    Group {
      if albumViewModel.downloadedAlbums.isEmpty && cachedSongs.isEmpty {
        LibraryPlaceholder(
          kind: .empty(
            systemImage: "arrow.down.circle", tint: .floLilac, title: "No downloads yet",
            message: "Download an album or playlist to play it without a connection."))
      } else {
        list
      }
    }
    .floNavigationTitle("Downloads")
    .measuresStorage($storage, trigger: storageChanges)
    .onAppear {
      albumViewModel.fetchDownloadedAlbums()
      cachedSongs = StreamCacheManager.shared.getCachedSongs()
    }
    .onChange(of: albumViewModel.downloadedAlbums, initial: true) { countSongs() }
    // An album being downloaded shows up here with its first song.
    .onReceive(downloads.downloadFinished) { id in
      if albumViewModel.downloadedAlbums.contains(where: { $0.id == id }) {
        songCounts[id] = DownloadStore.downloadedMediaFileIds(collectionId: id).count
      } else {
        albumViewModel.fetchDownloadedAlbums()
      }
      storageChanges += 1
    }
    .onReceive(downloads.downloadsRemoved) { storageChanges += 1 }
  }

  private var list: some View {
    List {
      storageCard
        .padding(.vertical, 9)
        .floJoinedRow(.alone)

      if !cachedSongs.isEmpty {
        NavigationLink(destination: WatchCachedSongsView(songs: cachedSongs)) {
          CoverRow(
            tile: .glyph("music.note.list"), title: "Cached songs",
            subtitle: counted(cachedSongs.count, "song"), tileSize: FloLayout.smallThumbnail
          ) {
            Chevron()
          }
        }
        .floJoinedRow(.alone)
      }

      let albums = albumViewModel.downloadedAlbums
      if !albums.isEmpty {
        Section {
          ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
            NavigationLink(destination: WatchAlbumDetailView(album: album)) {
              albumRow(album)
            }
            .floJoinedRow(RowPosition(index: index, count: albums.count))
          }
        } header: {
          FloSectionHeader("Albums")
        }
      }
    }
    .listStyle(.plain)
    // Not 0, at which watchOS leaves the list's last row undrawn.
    .environment(\.defaultMinListRowHeight, 1)
  }

  /// The downloads' size against the room left on the watch.
  private var storageCard: some View {
    VStack(spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(storage.downloads.fileSize)
          .font(.mono(13, relativeTo: .footnote))
        Spacer(minLength: 4)
        Text("\(storage.free.fileSize) free")
          .font(.floMeta)
          .foregroundStyle(Color.floSecondary)
      }
      .lineLimit(1)
      StorageBar(usage: storage, parts: [.init(color: .floLilac, bytes: storage.downloads)])
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Downloads \(storage.downloads.fileSize), \(storage.free.fileSize) free")
  }

  private func albumRow(_ album: Album) -> some View {
    let subtitle = [album.albumArtist, songCounts[album.id].map { counted($0, "song") } ?? ""]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    return CoverRow(
      tile: .cover(albumId: album.id), title: album.name, subtitle: subtitle,
      titleLineLimit: 2, tileSize: FloLayout.smallThumbnail
    ) {
      // An album shows up here with its first song, so the check waits until
      // its download has finished without a failure.
      if downloads.isDownloading(collectionId: album.id) {
        Text("\(Int(downloads.progress(collectionId: album.id) * 100))%")
          .font(.system(.footnote, weight: .semibold).monospacedDigit())
          .foregroundStyle(Color.floLilac)
      } else if phone.isReceiving(collectionId: album.id) {
        Image(systemName: "iphone.and.arrow.forward")
          .font(.system(size: 14))
          .foregroundStyle(Color.floLilac)
      } else if downloads.hasFailed(collectionId: album.id) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(Color.floDestructive)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(Color.floDownloaded)
      }
    }
  }

  private func countSongs() {
    songCounts = Dictionary(
      albumViewModel.downloadedAlbums.map {
        ($0.id, DownloadStore.downloadedMediaFileIds(collectionId: $0.id).count)
      },
      uniquingKeysWith: { first, _ in first })
  }
}
