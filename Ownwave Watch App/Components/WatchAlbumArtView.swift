//
//  WatchAlbumArtView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let albumId: String
  var size: CGFloat = FloLayout.thumbnail

  // The decoded cover, remembered together with the album it is for, so a
  // view reused for another album never shows the previous cover.
  @State private var loaded: (albumId: String, image: UIImage?)?

  private var image: UIImage? {
    loaded?.albumId == albumId ? loaded?.image : nil
  }

  private var loadFailed: Bool {
    loaded?.albumId == albumId && loaded?.image == nil
  }

  var body: some View {
    content
      .task(id: albumId) {
        guard !albumId.isEmpty, loaded?.albumId != albumId else { return }
        // The download's cover, else one download through the cover cache
        // that serves this view, every other view of the album and the Now
        // Playing artwork.
        let decoded = await CoverTint.decodedImage(albumId: albumId)
        // The view may have moved on to another album while this loaded.
        guard !Task.isCancelled else { return }
        loaded = (albumId, decoded)
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
      .foregroundStyle(Color.floSecondary)
      .frame(width: size, height: size)
      .background(Color.floSkeleton)
  }
}
