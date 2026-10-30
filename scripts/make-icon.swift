// Renders a logo image to a 1024px PNG for the app icon.
// Usage: swift make-icon.swift LOGO OUT.png
//
// macOS 26 shows every app icon as a rounded square and puts icons that don't
// fill it on a gray plate. The logo is full-bleed art, so it is scaled to cover
// the whole icon, centered, and macOS rounds the corners.
import AppKit

let size = 1024.0

let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let scale = max(size / logo.size.width, size / logo.size.height)
let w = logo.size.width * scale
let h = logo.size.height * scale

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
logo.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
