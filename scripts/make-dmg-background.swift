// Draws the DMG window background: an arrow from the app to the Applications
// folder and a line of instructions. build-dmg.sh places the icons at the
// points below, so keep them in sync.
// Usage: swift make-dmg-background.swift OUT.png SCALE
import AppKit

let width = 640.0, height = 400.0
// Icon centers, from the top left, as build-dmg.sh positions them.
let appX = 160.0, appsX = 480.0, iconY = 180.0
let green = NSColor(calibratedRed: 0.37, green: 0.80, blue: 0.42, alpha: 1)
let ink = NSColor(calibratedWhite: 0.25, alpha: 1)

let scale = Double(CommandLine.arguments[2])!
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// AppKit's origin is the bottom left; Finder's is the top left.
func y(_ top: Double) -> Double { height - top }

NSGradient(
    starting: NSColor(calibratedRed: 0.97, green: 0.99, blue: 0.97, alpha: 1),
    ending: NSColor(calibratedRed: 0.89, green: 0.96, blue: 0.90, alpha: 1)
)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// The arrow, between the two icons.
let start = appX + 90, end = appsX - 90, shaft = 14.0, head = 40.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: start, y: y(iconY) + shaft / 2))
arrow.line(to: NSPoint(x: end - head, y: y(iconY) + shaft / 2))
arrow.line(to: NSPoint(x: end - head, y: y(iconY) + head / 1.3))
arrow.line(to: NSPoint(x: end, y: y(iconY)))
arrow.line(to: NSPoint(x: end - head, y: y(iconY) - head / 1.3))
arrow.line(to: NSPoint(x: end - head, y: y(iconY) - shaft / 2))
arrow.line(to: NSPoint(x: start, y: y(iconY) - shaft / 2))
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 6
green.set()
arrow.fill()
arrow.stroke()

func text(_ s: String, size: Double, weight: NSFont.Weight, color: NSColor, top: Double) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.size().height
    str.draw(in: NSRect(x: 0, y: y(top) - h, width: width, height: h))
}
text("Install Substrate", size: 22, weight: .semibold, color: ink, top: 34)
text("Drag Substrate onto the Applications folder", size: 14, weight: .regular, color: ink, top: 318)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
