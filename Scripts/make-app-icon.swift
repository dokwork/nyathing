import AppKit
import Foundation

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: inputURL), source.size.width > 0, source.size.height > 0 else {
  fatalError("Unable to load app icon image at \(inputURL.path)")
}
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let iconSizes: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for (filename, pixels) in iconSizes {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else {
    fatalError("Unable to create \(pixels)x\(pixels) icon bitmap")
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

  let scale = min(CGFloat(pixels) / source.size.width, CGFloat(pixels) / source.size.height)
  let width = source.size.width * scale
  let height = source.size.height * scale
  source.draw(
    in: NSRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2,
               width: width, height: height),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
  )
  context.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode \(pixels)x\(pixels) icon")
  }
  try data.write(to: outputURL.appendingPathComponent(filename))
}
