//
//  WatchView.swift
//  Ownwave
//

import SwiftUI

/// The paired watch: whether it answers, its room, its sign-in, whether it
/// follows this phone's settings, what it holds, and albums to send.
struct WatchView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @ObservedObject private var link = WatchLink.shared
  @Environment(\.palette) private var palette

  @State private var shareSettings = UserDefaultsManager.shareWatchSettings
  @State private var position = ScrollPosition()

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        PageTitle("Watch")
        status
        if link.isPaired, link.isAppInstalled {
          if !link.isSignedIn { signInCard }
          shareRow
          onWatchSection
          if link.isSignedIn { suggestionsSection }
        } else {
          Text(
            link.isPaired
              ? "Install Ownwave on the watch from the Watch app to send music and sign it in."
              : "Pair an Apple Watch with this iPhone to send music to it."
          )
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .scrollPosition($position)
    .navigationBarTitleDisplayMode(.inline)
    // The tour's last step points at the albums to send, below the fold.
    .onChange(of: app.tour == .send && !suggestions.isEmpty, initial: true) {
      if $1 { withAnimation { position.scrollTo(id: TourStep.send, anchor: .top) } }
    }
    .onChange(of: shareSettings) {
      UserDefaultsManager.shareWatchSettings = $1
      link.updateWatch()
    }
    .task {
      albumViewModel.fetchDownloadedAlbums()
      await albumViewModel.loadRecentAlbums()
    }
    .followsSendProgress()
  }

  // MARK: - Status

  /// The watch's music share of its room as a ring, its connection and its
  /// sizes. The watch reports no other use, so the rest of the ring is free.
  private var status: some View {
    let watch = link.isPaired && link.isAppInstalled ? link.watch : nil
    return HStack(spacing: 18) {
      StorageRing(music: watch?.musicBytes ?? 0, free: watch?.freeBytes ?? 0)
      VStack(alignment: .leading, spacing: 2) {
        // No case size: the phone is not told it.
        Text("Apple Watch").font(.familjen(22, relativeTo: .title2))
        HStack(spacing: 6) {
          StatusDot(isOn: link.isPaired && link.isAppInstalled)
          Text(statusLine)
        }
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        if let watch {
          let music = Text(watch.musicBytes.fileSize)
            .fontWeight(.semibold)
            .foregroundStyle(palette.accent)
          Text("\(music) music · \(watch.freeBytes.fileSize) free")
            .font(.meta)
            .foregroundStyle(palette.secondary)
            .padding(.top, 6)
        }
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }

  private var statusLine: String {
    if !link.isPaired { return "No watch paired" }
    if !link.isAppInstalled { return "Ownwave is not on this watch" }
    // Reachable only while the app is in front; transfers go on without it.
    if link.isReachable { return "App open on the watch" }
    guard link.watch != nil else { return "Connected" }
    return link.isSignedIn ? "Connected · signed in" : "Connected · not signed in"
  }

  // MARK: - Sign-in and settings

  private var signInCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sign in the watch").font(.buttonLabel)
      Button(link.signIn == .sending ? "Sending to watch…" : "Sign in watch") {
        link.signInWatch()
      }
      .buttonStyle(FillButtonStyle(height: 48))
      .disabled(link.signIn == .sending)
      if case .failed(let message) = link.signIn {
        Text(message).font(.rowSubtitle).foregroundStyle(palette.secondary)
      }
    }
    .padding(16)
    .onPlatter()
  }

  private var shareRow: some View {
    Toggle(isOn: $shareSettings) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Share settings").font(.rowTitle.weight(.semibold))
        Text("Bitrates, Keep Playing, Mix variety and cellular downloads follow this iPhone")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
      }
    }
    .tint(palette.fill)
    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    .onPlatter()
  }

  // MARK: - Albums

  private var onWatchSection: some View {
    let albums = WatchAlbum.all(link)
    return VStack(spacing: 10) {
      HStack(spacing: 14) {
        SectionTitle("On the watch")
        if !albums.isEmpty {
          NavigationLink("See all \(albums.count)", value: Route.watchAlbums)
            .font(.rowSubtitle)
            .foregroundStyle(palette.accent)
        }
      }
      if albums.isEmpty {
        Text(WatchAlbum.emptyText(link))
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(albums) { ShelfTile(album: $0) }
          }
          .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
      }
    }
  }

  @ViewBuilder private var suggestionsSection: some View {
    let suggestions = suggestions
    if !suggestions.isEmpty {
      VStack(spacing: 10) {
        SectionTitle("Send to watch")
        Platter {
          ForEach(suggestions) { album in
            ItemRow(
              art: .cover(albumId: album.id), title: album.name, subtitle: album.albumArtist,
              artSize: 44
            ) {
              Button {
                link.send(album)
              } label: {
                Image(systemName: "arrow.up")
                  .font(.system(size: 15, weight: .bold))
                  .foregroundStyle(palette.accent)
                  .frame(width: 36, height: 36)
                  .background(palette.surface2, in: Circle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Send to Watch")
            }
            .itemMenu(.album(album))
          }
        }
      }
      .tourAnchor(.send)
      .id(TourStep.send)
    }
  }

  /// Recently played albums, then the ones downloaded here, that the watch
  /// neither holds nor is being sent.
  private var suggestions: [Album] {
    var skipped = Set((link.watch?.collections ?? []).map(\.id) + link.sends.map(\.id))
    return Array(
      (albumViewModel.recentAlbums + albumViewModel.downloadedAlbums)
        .filter { skipped.insert($0.id).inserted }
        .prefix(4))
  }
}

/// The watch's music against its room, around a watch glyph.
private struct StorageRing: View {
  let music: Int64
  let free: Int64

  @Environment(\.palette) private var palette

  private static let side: CGFloat = 96
  private static let width: CGFloat = 8

  var body: some View {
    let share = Double(music) / Double(max(music + free, 1))
    ZStack {
      Circle().stroke(palette.surface2, lineWidth: Self.width)
      // Round caps would draw a dot for nothing.
      if share > 0 {
        Circle()
          .trim(from: 0, to: share)
          .stroke(palette.accent, style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      Image(systemName: "applewatch")
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(palette.accent)
    }
    .padding(Self.width / 2)
    .frame(width: Self.side, height: Self.side)
    .accessibilityHidden(true)
  }
}

/// An album on the watch's shelf: the cover with a check once it is there,
/// or a progress bar while it is on its way.
private struct ShelfTile: View {
  let album: WatchAlbum

  @Environment(\.palette) private var palette

  private static let side: CGFloat = 112

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CoverArt(albumId: album.id, radius: 14)
        .frame(width: Self.side, height: Self.side)
        .overlay(alignment: .bottomTrailing) {
          if album.progress == nil {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(Color.floDownloaded)
              .frame(width: 22, height: 22)
              .background(palette.background, in: Circle())
              .padding(6)
          }
        }
        .overlay(alignment: .bottom) {
          if let progress = album.progress {
            // Over any cover, so in fixed colors as the design has them.
            GeometryReader { proxy in
              Capsule().fill(.black.opacity(0.45))
                .overlay(alignment: .leading) {
                  Capsule().fill(.white).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
            .padding(8)
          }
        }
      Text(album.name)
        .font(.meta.weight(.semibold))
        .lineLimit(1)
        .padding(.top, 6)
      Text(album.subtitle(withBitrate: false))
        .font(.caption)
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
    }
    .frame(width: Self.side)
    .contentShape(Rectangle())
    .watchAlbumMenu(album)
  }
}
