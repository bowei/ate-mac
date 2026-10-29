// Renders an SF Symbol to a 1024px PNG for the app icon.
// Usage: swift make-icon.swift OUT.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 180, yRadius: 180)
    NSColor(calibratedRed: 0.16, green: 0.33, blue: 0.75, alpha: 1).setFill()
    bg.fill()
    let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    return true
}
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
