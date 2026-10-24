//
//  WatchAlbumsView.swift
//  Ownwave
//

import SwiftUI

/// Every album on the watch and those on their way, from the Watch screen's See all.
struct WatchAlbumsView: View {
  @ObservedObject private var link = WatchLink.shared
  @Environment(\.palette) private var palette

  var body: some View {
    let albums = WatchAlbum.all(link)
    ScrollView {
      VStack(spacing: 14) {
        PageTitle("On the watch")
        if albums.isEmpty {
          Text(WatchAlbum.emptyText(link))
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        } else {
          Platter {
            ForEach(albums) { album in
              ItemRow(
                art: .cover(albumId: album.id), title: album.name,
                subtitle: album.subtitle(withBitrate: true), artSize: 44
              ) {
                // The subtitle says how far one on its way is.
                if album.progress == nil {
                  Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.floDownloaded)
                }
              }
              .watchAlbumMenu(album)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// An album on the watch or on its way there, as the Watch screen's shelf
/// and its full list show it.
struct WatchAlbum: Identifiable {
  enum State {
    /// Downloaded here and handed to the watch.
    case sending
    /// The watch downloads it from the server itself.
    case downloading
    case onWatch
  }

  let id: String
  let name: String
  let state: State
  let songs: Int
  var kbps: Int?
  /// 0...1 while sending or downloading, else nil.
  var progress: Double?

  /// Sends first, then what the watch holds. An album still arriving shows
  /// once, as a send.
  @MainActor static func all(_ link: WatchLink) -> [WatchAlbum] {
    let sends = link.sends.map {
      WatchAlbum(
        id: $0.id, name: $0.album.name, state: .sending, songs: $0.songs, progress: $0.progress)
    }
    let held = (link.watch?.collections ?? []).compactMap { collection -> WatchAlbum? in
      guard link.watch?.incoming[collection.id] == nil,
        !link.sends.contains(where: { $0.id == collection.id })
      else { return nil }
      let left = collection.downloading ?? 0
      return WatchAlbum(
        id: collection.id, name: collection.name, state: left > 0 ? .downloading : .onWatch,
        songs: collection.songs, kbps: collection.kbps,
        progress: left > 0 ? Double(collection.songs) / Double(collection.songs + left) : nil)
    }
    return sends + held
  }

  @MainActor static func emptyText(_ link: WatchLink) -> String {
    link.watch == nil ? "The watch has not reported yet." : "Nothing on the watch yet."
  }

  /// "Sending · 62%", "Downloading · 40%" or "15 songs", with the bitrate
  /// "15 songs · 192 kbps".
  func subtitle(withBitrate: Bool) -> String {
    let percent = "\(Int((progress ?? 0) * 100))%"
    switch state {
    case .sending: return "Sending · \(percent)"
    case .downloading: return "Downloading · \(percent)"
    case .onWatch:
      let kbps = withBitrate ? kbps.map { " · \($0) kbps" } ?? "" : ""
      return counted(songs, "song") + kbps
    }
  }
}

extension View {
  /// Stop Sending on an album on its way: a send that hangs (a watch app
  /// reinstalled meanwhile) can go again.
  @ViewBuilder func watchAlbumMenu(_ album: WatchAlbum) -> some View {
    if album.state == .sending {
      contextMenu {
        Button("Stop Sending", systemImage: "xmark", role: .destructive) {
          WatchLink.shared.stopSend(album.id)
        }
      }
    } else {
      self
    }
  }

  /// The system reports no transfer progress by itself; the sends' progress
  /// follows it here while any are under way.
  func followsSendProgress() -> some View {
    modifier(SendProgress())
  }
}

private struct SendProgress: ViewModifier {
  @ObservedObject private var link = WatchLink.shared

  func body(content: Content) -> some View {
    content.task(id: link.sends.isEmpty) {
      while !link.sends.isEmpty, !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        link.sends.map(\.id).forEach { link.updateProgress($0) }
      }
    }
  }
}
