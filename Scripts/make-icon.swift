// Draws ChargePilot's app icon: a rounded tile with a battery filled to a marked limit.
import AppKit

let output = CommandLine.arguments[1]
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.11, green: 0.20, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.13, alpha: 1),
    ])!.draw(in: tilePath, angle: -90)

    // Battery body.
    let body = NSRect(x: 230, y: 380, width: 520, height: 264)
    let outline = NSBezierPath(roundedRect: body, xRadius: 62, yRadius: 62)
    outline.lineWidth = 30
    NSColor(white: 0.92, alpha: 1).setStroke()
    outline.stroke()
    NSColor(white: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 768, y: 460, width: 34, height: 104), xRadius: 17, yRadius: 17).fill()

    // Charge up to 80 %.
    let inner = body.insetBy(dx: 42, dy: 42)
    let level = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.8, height: inner.height)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.70, blue: 0.47, alpha: 1),
    ])!.draw(in: NSBezierPath(roundedRect: level, xRadius: 26, yRadius: 26), angle: -90)

    // The limit marker.
    let x = inner.minX + inner.width * 0.8 + 20
    NSColor(calibratedRed: 1, green: 0.78, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 9, y: body.minY - 70, width: 18, height: body.height + 140), xRadius: 9, yRadius: 9).fill()

    // Graduations below.
    NSColor(white: 0.92, alpha: 0.55).setFill()
    for i in 0...10 {
        let gx = inner.minX + inner.width * CGFloat(i) / 10 - 4
        let h: CGFloat = i % 5 == 0 ? 56 : 30
        NSBezierPath(roundedRect: NSRect(x: gx, y: 250, width: 8, height: h), xRadius: 4, yRadius: 4).fill()
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
