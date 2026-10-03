//
//  WatchAlbumArtView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let url: String
  var size: CGFloat = 36
  var albumId: String = ""

  // The cover cache's answer, remembered together with the album it is for,
  // so a view reused for another album never shows the previous cover.
  @State private var cached: (albumId: String, path: String?)?

  private var cachedPath: String? {
    cached?.albumId == albumId ? cached?.path : nil
  }

  private var cacheFailed: Bool {
    cached?.albumId == albumId && cached?.path == nil
  }

  var body: some View {
    content
      .task(id: albumId) {
        guard !url.hasPrefix("/"), !albumId.isEmpty, cached?.albumId != albumId else { return }
        // One download through the cover cache serves this view, every other
        // view of the album and the Now Playing artwork.
        let path = await CoverArtCacheManager.shared.coverPath(albumId: albumId)
        // The view may have moved on to another album while this loaded.
        guard !Task.isCancelled else { return }
        cached = (albumId, path)
      }
  }

  @ViewBuilder
  private var content: some View {
    if let path = url.hasPrefix("/") ? url : cachedPath,
      let uiImage = UIImage(contentsOfFile: path)
    {
      Image(uiImage: uiImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
    } else if !albumId.isEmpty, !cacheFailed {
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
