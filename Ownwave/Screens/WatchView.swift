//
//  WatchView.swift
//  Ownwave
//

import SwiftUI

/// The paired watch: whether it answers, what it holds and its room, its
/// sign-in, whether it follows this phone's settings, and albums to send.
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
        statusCard
        if link.isPaired, link.isAppInstalled {
          signInCard
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
  }

  // MARK: - Status

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        GlyphTile(systemImage: "applewatch", radius: 16).frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 2) {
          // No case size: the phone is not told it.
          Text("Apple Watch").font(.buttonLabel)
          HStack(spacing: 6) {
            Circle()
              .fill(
                link.isReachable && link.isAppInstalled ? Color.floDownloaded : palette.secondary
              )
              .frame(width: 7, height: 7)
            Text(statusLine)
          }
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
        }
        Spacer(minLength: 0)
      }
      if link.isPaired, link.isAppInstalled, let watch = link.watch {
        StorageBar(music: watch.musicBytes, free: watch.freeBytes)
      }
    }
    .padding(16)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private var statusLine: String {
    if !link.isPaired { return "No watch paired" }
    if !link.isAppInstalled { return "Ownwave is not on this watch" }
    return link.isReachable ? "Reachable" : "Not reachable right now"
  }

  // MARK: - Sign-in and settings

  @ViewBuilder private var signInCard: some View {
    if link.isSignedIn, let account = link.watch?.account {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 22))
          .foregroundStyle(Color.floDownloaded)
        VStack(alignment: .leading, spacing: 1) {
          Text("Watch signed in").font(.rowTitle.weight(.semibold))
          Text("\(account.user) · \(account.host)")
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    } else {
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
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }

  private var shareRow: some View {
    Toggle(isOn: $shareSettings) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Share settings").font(.rowTitle.weight(.semibold))
        Text("Bitrates and Keep Playing follow this iPhone")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
      }
    }
    .tint(Color.floDownloaded)
    .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  // MARK: - Albums

  private var onWatchSection: some View {
    // An album still arriving shows once, as a send, not also with a check.
    let collections = (link.watch?.collections ?? []).filter { collection in
      link.watch?.incoming[collection.id] == nil && !link.sends.contains { $0.id == collection.id }
    }
    return VStack(spacing: 8) {
      SectionTitle("On the watch")
      ForEach(collections) { collection in
        let kbps = collection.kbps.map { " · \($0) kbps" } ?? ""
        ItemRow(
          art: .cover(albumId: collection.id), title: collection.name,
          subtitle: counted(collection.songs, "song") + kbps, artSize: 44
        ) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.floDownloaded)
        }
        .card()
      }
      ForEach(link.sends) { SendRow(send: $0) }
      if collections.isEmpty, link.sends.isEmpty {
        Text(link.watch == nil ? "The watch has not reported yet." : "Nothing on the watch yet.")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
      }
    }
  }

  @ViewBuilder private var suggestionsSection: some View {
    let suggestions = suggestions
    if !suggestions.isEmpty {
      VStack(spacing: 8) {
        SectionTitle("Send to watch")
        ForEach(suggestions) { album in
          ItemRow(
            art: .cover(albumId: album.id), title: album.name, subtitle: album.albumArtist,
            artSize: 44
          ) {
            Button("Send") { link.send(album) }
              .font(.rowSubtitle.weight(.bold))
              .foregroundStyle(palette.accent)
              .padding(.vertical, 7)
              .padding(.horizontal, 14)
              .background(palette.surface2, in: Capsule())
              .buttonStyle(.plain)
          }
          .card()
          .itemMenu(.album(album))
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

/// The watch's music and free room as one bar with a legend. The watch
/// reports no other use, so the rest of the bar is free.
private struct StorageBar: View {
  let music: Int64
  let free: Int64

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { proxy in
        let total = max(music + free, 1)
        palette.surface2
          .overlay(alignment: .leading) {
            palette.accent.frame(width: proxy.size.width * Double(music) / Double(total))
          }
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .frame(height: 10)
      HStack(spacing: 14) {
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 8, height: 8)
          Text("Music \(Self.size(music))")
        }
        Text("\(Self.size(free)) free")
      }
      .font(.meta)
      .foregroundStyle(palette.secondary)
    }
  }

  private static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// An album on its way to the watch, with its progress.
private struct SendRow: View {
  let send: WatchLink.Send

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 12) {
      CoverArt(albumId: send.album.id, radius: 7).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(send.album.name).font(.rowTitle).lineLimit(1)
        Text("Sending").font(.rowSubtitle).foregroundStyle(palette.secondary)
        // The Downloads list's look for the same thing.
        ProgressView(value: send.progress).tint(palette.accent).padding(.top, 3)
      }
      Text("\(Int(send.progress * 100))%")
        .font(.rowSubtitle)
        .monospacedDigit()
        .foregroundStyle(palette.secondary)
    }
    .padding(.vertical, 8)
    .card()
  }
}
