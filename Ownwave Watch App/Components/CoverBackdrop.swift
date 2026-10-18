//
//  CoverBackdrop.swift
//  Ownwave Watch App
//

import SwiftUI
import UIKit

/// The cover filling the top of a screen, fading to black below.
struct CoverBackdrop: View {
  let albumId: String
  /// The resolved cover, a local path for downloaded albums.
  var url: String = ""
  /// Nil fills the whole screen.
  var height: CGFloat?

  @State private var image: (albumId: String, image: UIImage?)?

  var body: some View {
    ZStack(alignment: .top) {
      Color.black
      if let uiImage = image?.albumId == albumId ? image?.image : nil {
        Image(uiImage: uiImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity)
          .frame(height: height)
          .frame(maxHeight: height == nil ? .infinity : nil)
          .clipped()
          .overlay(
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .black.opacity(0.62), location: 0.38),
                .init(color: .black.opacity(0.92), location: 0.70),
                .init(color: .black, location: 0.88),
              ], startPoint: .top, endPoint: .bottom)
          )
      }
    }
    .ignoresSafeArea()
    .task(id: albumId) {
      guard image?.albumId != albumId else { return }
      let path = await CoverTint.coverFile(albumId: albumId, url: url)
      // Decoding a full cover would stall the main thread mid-transition.
      let decoded = await Task.detached(priority: .userInitiated) {
        path.flatMap(UIImage.init(contentsOfFile:)).flatMap(CoverTint.decoded)
      }.value
      guard !Task.isCancelled else { return }
      image = (albumId, decoded)
    }
  }
}
