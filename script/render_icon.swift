import AppKit
import Foundation

// Render the editable SVG with macOS's SVG decoder, preserving transparency.
let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0,
       let image = NSImage(contentsOfFile: args[1]),
       let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
       let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("usage: swift script/render_icon.swift input.svg output.png size\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
