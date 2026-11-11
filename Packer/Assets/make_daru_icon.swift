import AppKit
import Foundation

// Turn the exact user-provided black-cat PNG into a 1024x1024 filled iOS icon.
// Do not redraw or replace the artwork; the iPhone system supplies the icon mask.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make_icon.swift input.png output.png")
}
let source = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
guard let icon = NSImage(contentsOfFile: source) else {
    fatalError("Could not load the user-supplied icon")
}
let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: image)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor(calibratedRed: 250.0/255.0, green: 250.0/255.0, blue: 249.0/255.0, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
          from: .zero, operation: .sourceOver, fraction: 1.0)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = image.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode AppIcon PNG")
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Generated 1024x1024 daru icon: \(output)")
