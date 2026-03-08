//
//  WatchAlbumArtView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumArtView: View {
  let url: String
  var size: CGFloat = 36
  var albumId: String = ""

  var body: some View {
    if url.hasPrefix("/"), let uiImage = UIImage(contentsOfFile: url) {
      Image(uiImage: uiImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
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
      .task {
        if !albumId.isEmpty {
          CoverArtCacheManager.shared.cacheIfNeeded(albumId: albumId)
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
