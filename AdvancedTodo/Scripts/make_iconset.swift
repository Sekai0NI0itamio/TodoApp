import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: make_iconset.swift <source.png> <output.iconset>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)

let image = NSImage(contentsOf: sourceURL) ?? NSImage(size: .zero)
guard image.size.width > 0, image.size.height > 0 else {
    fputs("Failed to load source image\n", stderr)
    exit(1)
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func roundedImage(from image: NSImage, size: CGFloat) -> NSImage? {
    let targetSize = NSSize(width: size, height: size)
    let output = NSImage(size: targetSize)
    output.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        output.unlockFocus()
        return nil
    }

    let rect = CGRect(origin: .zero, size: targetSize)
    let radius = size * 0.223
    let maskPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    context.saveGState()
    context.addPath(maskPath)
    context.clip()
    image.draw(in: rect, from: CGRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
    context.restoreGState()

    output.unlockFocus()
    return output
}

func pngData(from image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

for (filename, size) in sizes {
    guard let rendered = roundedImage(from: image, size: size),
          let data = pngData(from: rendered) else {
        fputs("Failed to render icon size \(Int(size))\n", stderr)
        exit(1)
    }
    let destination = outputDirectory.appendingPathComponent(filename)
    try data.write(to: destination)
}
