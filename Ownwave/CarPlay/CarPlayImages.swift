//
//  CarPlayImages.swift
//  Ownwave
//

import CarPlay
import SwiftUI

/// The pictures in the car's lists: covers, glyph tiles, track numbers and
/// status marks, drawn at the car screen's scale. Everything but a cover
/// comes in the Dusk palette's dark and light shades, which the car picks
/// between itself.
@MainActor final class CarPlayImages {
  /// A tile's colors: the background and the symbol on it.
  enum Tile {
    /// Accent on the glyph tile, as the phone's GlyphTile.
    case glyph
    /// Ink on the fill, as the phone's Play Something button.
    case filled
    /// The liked red on the glyph tile.
    case liked

    fileprivate func colors(_ palette: Palette) -> (background: Color, symbol: Color) {
      switch self {
      case .glyph: (palette.surface2, palette.accent)
      case .filled: (palette.fill, palette.ink)
      case .liked: (palette.surface2, .floLiked)
      }
    }
  }

  /// A list row's image, in points.
  static var rowSize: CGSize { CPListItem.maximumImageSize }
  /// An image of the Pinned and Recently Played rows, in points.
  static var elementSize: CGSize { CPListImageRowItemRowElement.maximumImageSize }

  private let scale: CGFloat
  private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 16 << 20
    return cache
  }()

  init(traits: UITraitCollection) {
    scale = max(traits.displayScale, 1)
  }

  /// The album's cover, decoded off the main thread at `size`; nil when
  /// there is none.
  func cover(albumId: String, url: String = "", size: CGSize) async -> UIImage? {
    let pixels = Int(max(size.width, size.height) * scale)
    let key = "cover:\(albumId)@\(pixels)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let path = await CoverTint.coverFile(albumId: albumId, url: url)
    guard
      let cgImage = await Task.detached(
        priority: .userInitiated,
        operation: {
          path.flatMap { Thumbnail.image(URL(fileURLWithPath: $0), pixels: pixels) }
        }
      ).value
    else { return nil }
    let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
    return image
  }

  /// An SF Symbol on a rounded tile, or on a circle.
  func tile(_ symbol: String, _ style: Tile = .glyph, round: Bool = false, size: CGSize)
    -> UIImage
  {
    themed("tile:\(symbol):\(style):\(round)", size: size) { palette, rect in
      let colors = style.colors(palette)
      let radius = round ? rect.width / 2 : rect.width * 0.18
      UIColor(colors.background).setFill()
      UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
      let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .medium)
      guard let glyph = UIImage(systemName: symbol, withConfiguration: config) else { return }
      glyph.withTintColor(UIColor(colors.symbol)).draw(
        in: CGRect(
          x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
          width: glyph.size.width, height: glyph.size.height))
    }
  }

  /// A track number, in the secondary text color.
  func number(_ number: Int, size: CGSize) -> UIImage {
    themed("number:\(number)", size: size) { palette, rect in
      let text = String(number) as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: rect.height * 0.4, weight: .medium),
        .foregroundColor: UIColor(palette.secondary),
      ]
      let bounds = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2),
        withAttributes: attributes)
    }
  }

  /// A status mark at the end of a row, in its own color in both schemes.
  func status(_ symbol: String, color: Color) -> UIImage? {
    UIImage(systemName: symbol)?.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
  }

  /// Where a loaded cover goes: a list row or an element of an image row.
  enum Cover {
    case row(CPListItem, albumId: String)
    case element(CPListImageRowItemRowElement, albumId: String)
  }

  /// Puts each album's cover in place, top down and one at a time, so a
  /// long list asks for the covers it shows first; a cover not found keeps
  /// the placeholder. Rows replaced or popped meanwhile are skipped, so the
  /// loading ends with the list.
  func loadCovers(_ covers: [Cover], size: CGSize) {
    // Each target holds its row weakly and hands out a setter while it lives.
    let targets = covers.map { cover -> (albumId: String, setter: () -> ((UIImage) -> Void)?) in
      switch cover {
      case .row(let item, let albumId):
        (albumId, { [weak item] in item.map { item in { item.setImage($0) } } })
      case .element(let element, let albumId):
        (albumId, { [weak element] in element.map { element in { element.image = $0 } } })
      }
    }
    Task { [weak self] in
      for target in targets where !target.albumId.isEmpty {
        guard let self else { return }
        guard let set = target.setter() else { continue }
        if let image = await cover(albumId: target.albumId, size: size) { set(image) }
      }
    }
  }

  /// Draws the image once per palette and joins the two in one asset, so the
  /// car shows the shade that matches its own appearance.
  private func themed(_ name: String, size: CGSize, draw: (Palette, CGRect) -> Void) -> UIImage {
    let key = "\(name)@\(Int(size.width))x\(Int(size.height))" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let asset = UIImageAsset()
    for (palette, style) in [(Palette.dark, UIUserInterfaceStyle.dark), (.light, .light)] {
      let image = renderer.image { _ in draw(palette, CGRect(origin: .zero, size: size)) }
      asset.register(
        image,
        with: UITraitCollection {
          $0.userInterfaceStyle = style
          $0.displayScale = scale
        })
    }
    let image = asset.image(with: UITraitCollection(displayScale: scale))
    let pixels = Int(size.width * scale) * Int(size.height * scale) * 4 * 2
    cache.setObject(image, forKey: key, cost: pixels)
    return image
  }
}
