//
//  CoverTint.swift
//  flo
//

import SwiftUI
import UIKit

/// The cover's hue (OKLCH, from its average color) and the colors built on
/// it. The watch's tint is that hue at lightness 0.86 and chroma 0.1, so it
/// reads on black at any hue. Gray covers have no hue worth keeping and get
/// nil (use lilac).
enum CoverTint {
  @MainActor private static var memo: [String: Double?] = [:]

  /// A local `url` or the album's downloaded cover first, the cover cache
  /// otherwise, so offline playback keeps its artwork.
  static func coverFile(albumId: String, url: String = "", artId: String? = nil) async
    -> String?
  {
    if url.hasPrefix("/"), FileManager.default.fileExists(atPath: url) { return url }
    guard !albumId.isEmpty else { return nil }
    if let downloaded = DownloadStore.downloadedCoverPath(albumId: albumId) {
      return downloaded
    }
    return await CoverArtCacheManager.shared.coverPath(albumId: albumId, artId: artId)
  }

  @MainActor
  static func color(albumId: String, url: String = "") async -> Color? {
    await hue(albumId: albumId, url: url).map { color(hue: $0, lightness: 0.86, chroma: 0.1) }
  }

  /// The cover's OKLCH hue in radians, memoized per album.
  @MainActor
  static func hue(albumId: String, url: String = "") async -> Double? {
    guard !albumId.isEmpty else { return nil }
    if let known = memo[albumId] { return known }
    guard let path = await coverFile(albumId: albumId, url: url) else { return nil }
    let found = await Task.detached(priority: .utility) { () -> Double? in
      guard let image = UIImage(contentsOfFile: path), let rgb = averageColor(of: image)
      else { return nil }
      return hue(of: rgb)
    }.value
    memo[albumId] = found
    return found
  }

  /// The cover (as `coverFile` finds it) drawn into a bitmap off the main
  /// thread: decoding a full cover there would stall a transition or every
  /// redraw.
  static func decodedImage(albumId: String, url: String = "", artId: String? = nil) async
    -> UIImage?
  {
    let path = await coverFile(albumId: albumId, url: url, artId: artId)
    return await Task.detached(priority: .userInitiated) {
      path.flatMap(UIImage.init(contentsOfFile:)).flatMap(decoded)
    }.value
  }

  /// The image drawn once into a bitmap, so it is not decoded while drawing.
  private nonisolated static func decoded(_ image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage,
      let context = CGContext(
        data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return image }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return context.makeImage().map { UIImage(cgImage: $0) } ?? image
  }

  /// Average sRGB color of the image, drawn down to 8×8.
  private static func averageColor(of image: UIImage) -> (Double, Double, Double)? {
    guard let cgImage = image.cgImage else { return nil }
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    var sum = (0.0, 0.0, 0.0)
    for i in stride(from: 0, to: pixels.count, by: 4) {
      sum.0 += Double(pixels[i])
      sum.1 += Double(pixels[i + 1])
      sum.2 += Double(pixels[i + 2])
    }
    let count = Double(side * side) * 255
    return (sum.0 / count, sum.1 / count, sum.2 / count)
  }

  private static func hue(of rgb: (Double, Double, Double)) -> Double? {
    func linear(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    let (r, g, b) = (linear(rgb.0), linear(rgb.1), linear(rgb.2))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    let labA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    let labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    guard (labA * labA + labB * labB).squareRoot() >= 0.03 else { return nil }
    return atan2(labB, labA)
  }

  /// The sRGB color of an OKLCH lightness, chroma and hue (radians).
  static func color(hue: Double, lightness: Double, chroma: Double) -> Color {
    func gamma(_ c: Double) -> Double {
      let c = min(max(c, 0), 1)
      return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    let a = chroma * cos(hue)
    let bb = chroma * sin(hue)
    let l2 = pow(lightness + 0.3963377774 * a + 0.2158037573 * bb, 3)
    let m2 = pow(lightness - 0.1055613458 * a - 0.0638541728 * bb, 3)
    let s2 = pow(lightness - 0.0894841775 * a - 1.2914855480 * bb, 3)
    return Color(
      red: gamma(4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2),
      green: gamma(-1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2),
      blue: gamma(-0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2))
  }
}

/// The colors derived from a cover's hue, light and dark; the watch only
/// knows dark.
struct CoverShades {
  /// Text, icons and the Play fill.
  let tint: Color
  /// Behind tinted elements.
  let background: Color

  init(hue: Double, scheme: ColorScheme) {
    let dark = scheme == .dark
    tint = CoverTint.color(hue: hue, lightness: dark ? 0.86 : 0.48, chroma: dark ? 0.1 : 0.14)
    background = CoverTint.color(hue: hue, lightness: dark ? 0.3 : 0.9, chroma: dark ? 0.07 : 0.05)
  }
}

extension View {
  /// Keeps `shades` at the colors of the album's cover in the color scheme
  /// in use; nil until the cover is read, and for a gray one.
  func coverShades(_ shades: Binding<CoverShades?>, albumId: String, url: String = "") -> some View
  {
    modifier(CoverShading(shades: shades, albumId: albumId, url: url))
  }
}

private struct CoverShading: ViewModifier {
  @Binding var shades: CoverShades?
  let albumId: String
  let url: String

  @Environment(\.colorScheme) private var scheme

  private struct Key: Equatable {
    let albumId: String
    let scheme: ColorScheme
  }

  func body(content: Content) -> some View {
    // The hue is memoized per album, so a new scheme only mixes the colors.
    content.task(id: Key(albumId: albumId, scheme: scheme)) {
      let hue = await CoverTint.hue(albumId: albumId, url: url)
      shades = hue.map { CoverShades(hue: $0, scheme: scheme) }
    }
  }
}
