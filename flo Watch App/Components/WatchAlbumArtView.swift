//
//  WatchAlbumArtView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let url: String
  var size: CGFloat = 36
  var albumId: String = ""

  @State private var cachedPath: String?
  @State private var cacheFailed = false

  var body: some View {
    if let path = url.hasPrefix("/") ? url : cachedPath,
      let uiImage = UIImage(contentsOfFile: path)
    {
      Image(uiImage: uiImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
    } else if !albumId.isEmpty, !cacheFailed {
      // One download through the cover cache serves this view, every other
      // view of the album and the Now Playing artwork.
      ProgressView()
        .frame(width: size, height: size)
        .task(id: albumId) {
          cachedPath = await CoverArtCacheManager.shared.coverPath(albumId: albumId)
          cacheFailed = cachedPath == nil
        }
    } else if let imageURL = URL(string: url) {
      AsyncImage(url: imageURL) { phase in
        switch phase {
        case .success(let image):
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
        case .failure:
          placeholderView
        case .empty:
          ProgressView()
            .frame(width: size, height: size)
        @unknown default:
          placeholderView
        }
      }
    } else {
      placeholderView
    }
  }

  private var placeholderView: some View {
    Image(systemName: "music.note")
      .font(.system(size: size * 0.4))
      .foregroundColor(.secondary)
      .frame(width: size, height: size)
      .background(Color.secondary.opacity(0.2))
  }
}
