//
//  WatchAlbumArtView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let albumId: String
  /// A cover of its own, such as a playlist's mosaic; the album's when nil.
  var artId: String?
  var size: CGFloat = WatchLayout.thumbnail

  // The decoded cover, remembered together with the cover it is, so a view
  // reused for another album never shows the previous cover.
  @State private var loaded: (key: String, image: UIImage?)?
  // A cover that failed is tried again when the server comes back.
  @State private var reachable = ConnectivityMonitor.shared.isServerReachable

  private var key: String { albumId + "|" + (artId ?? "") }

  private var image: UIImage? {
    loaded?.key == key ? loaded?.image : nil
  }

  private var loadFailed: Bool {
    loaded?.key == key && loaded?.image == nil
  }

  var body: some View {
    content
      .onReceive(ConnectivityMonitor.shared.$isServerReachable.removeDuplicates()) {
        reachable = $0
      }
      .task(id: "\(key)|\(reachable)") {
        let key = key
        guard !albumId.isEmpty, loaded?.key != key || loaded?.image == nil else { return }
        // The download's cover, else one download through the cover cache
        // that serves this view, every other view of the album and the Now
        // Playing artwork.
        let decoded = await CoverTint.decodedImage(albumId: albumId, artId: artId)
        // The view may have moved on to another album while this loaded.
        guard !Task.isCancelled else { return }
        loaded = (key, decoded)
      }
  }

  @ViewBuilder
  private var content: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
    } else if !albumId.isEmpty, !loadFailed {
      ProgressView()
        .frame(width: size, height: size)
    } else {
      placeholderView
    }
  }

  private var placeholderView: some View {
    Image(systemName: "music.note")
      .font(.system(size: size * 0.4))
      .foregroundStyle(Dusk.secondary)
      .frame(width: size, height: size)
      .background(Dusk.skeleton)
  }
}
