//
//  WatchAlbumArtView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let url: String
  var size: CGFloat = 36
  var albumId: String = ""

  // The decoded cover, remembered together with the cover it is for, so a
  // view reused for another album never shows the previous cover.
  @State private var loaded: (key: String, image: UIImage?)?

  private var isLocal: Bool { url.hasPrefix("/") }
  private var key: String { isLocal ? url : albumId }

  private var image: UIImage? {
    loaded?.key == key ? loaded?.image : nil
  }

  private var loadFailed: Bool {
    loaded?.key == key && loaded?.image == nil
  }

  var body: some View {
    content
      .task(id: key) {
        guard isLocal || !albumId.isEmpty, loaded?.key != key else { return }
        // One download through the cover cache serves this view, every other
        // view of the album and the Now Playing artwork.
        let path: String? =
          isLocal ? url : await CoverArtCacheManager.shared.coverPath(albumId: albumId)
        // Decoding in body would stall the main thread on every redraw.
        let decoded = await Task.detached(priority: .userInitiated) {
          path.flatMap(UIImage.init(contentsOfFile:)).flatMap(CoverTint.decoded)
        }.value
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
    } else if isLocal || !albumId.isEmpty, !loadFailed {
      ProgressView()
        .frame(width: size, height: size)
    } else {
      placeholderView
    }
  }

  private var placeholderView: some View {
    Image(systemName: "music.note")
      .font(.system(size: size * 0.4))
      .foregroundStyle(Color.floSecondary)
      .frame(width: size, height: size)
      .background(Color.floSkeleton)
  }
}
