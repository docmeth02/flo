// Renders the Ownwave app icon: seven ink bars on lilac, drawn on a 104 unit
// grid and written as a 1024 px opaque sRGB PNG, since App Store Connect
// rejects an icon with an alpha channel.
//
//   swift scripts/render-icon.swift "Ownwave Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let pixels = 1024
let grid: CGFloat = 104
let barWidth: CGFloat = 7
let barGap: CGFloat = 5
let barRadius: CGFloat = 5
let barHeights: [CGFloat] = [33, 64, 23, 79, 43, 59, 28]

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write("usage: render-icon.swift <output.png>\n".data(using: .utf8)!)
  exit(1)
}

let context = CGContext(
  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(color(0xC4A4FE))
context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

context.scaleBy(x: CGFloat(pixels) / grid, y: CGFloat(pixels) / grid)
context.setFillColor(color(0x120E22))
let rowWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
// A radius past half the width is clamped, as SVG does, so the ends are round.
let radius = min(barRadius, barWidth / 2)
for (index, height) in barHeights.enumerated() {
  let bar = CGRect(
    x: (grid - rowWidth) / 2 + CGFloat(index) * (barWidth + barGap), y: (grid - height) / 2,
    width: barWidth, height: height)
  context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
}
context.fillPath()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
  FileHandle.standardError.write("could not write \(url.path)\n".data(using: .utf8)!)
  exit(1)
}
