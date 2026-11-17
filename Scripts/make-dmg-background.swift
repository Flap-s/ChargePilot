// Draws the background of the installer disk image window: a title, an arrow from the app to the Applications
// folder, and a hint for the first launch. Usage: swift make-dmg-background.swift <output.png> <scale>
// The window is 640 × 400 points; the icons sit at x = 170 and x = 470, y = 200 (from the top).
import AppKit

let output = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1") ?? 1)
let size = NSSize(width: 640, height: 400)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
        .kern: tracking,
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let bounds = attributed.boundingRect(with: NSSize(width: 560, height: 200), options: [.usesLineFragmentOrigin])
    // Drawing is flipped below: y grows downwards.
    attributed.draw(with: NSRect(x: centerX - 280, y: top, width: 560, height: bounds.height), options: [.usesLineFragmentOrigin])
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
let bitmapContext = NSGraphicsContext(bitmapImageRep: rep)!
// Top-left origin, like Finder's icon coordinates; the context is declared flipped so text draws upright.
bitmapContext.cgContext.translateBy(x: 0, y: size.height)
bitmapContext.cgContext.scaleBy(x: 1, y: -1)
let context = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)
NSGraphicsContext.current = context

let bounds = NSRect(origin: .zero, size: size)

// Deep teal backdrop, the app icon's colours, with a soft glow behind the icons.
NSGradient(colors: [color(0x16303A), color(0x0B1A20)])!.draw(in: bounds, angle: -90)
NSGradient(colors: [color(0x2FB37A, 0.20), color(0x2FB37A, 0)])!
    .draw(fromCenter: NSPoint(x: 320, y: 200), radius: 0, toCenter: NSPoint(x: 320, y: 200), radius: 330, options: [])

// Faint charge graduations along the bottom, echoing the icon.
for i in 0...40 {
    let x = 40 + CGFloat(i) * 14
    let major = i % 5 == 0
    color(0xFFFFFF, major ? 0.10 : 0.05).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 1, y: major ? 336 : 342, width: 2, height: major ? 14 : 8), xRadius: 1, yRadius: 1).fill()
}
// The 80 % marker.
color(0xFFC84D, 0.55).setFill()
NSBezierPath(roundedRect: NSRect(x: 40 + 32 * 14 - 1.5, y: 330, width: 3, height: 22), xRadius: 1.5, yRadius: 1.5).fill()

// Title.
text("Installer ChargePilot", size: 24, weight: .semibold, color: .white, centerX: 320, top: 34, tracking: 0.2)
text("Glissez l'application dans le dossier Applications", size: 14, weight: .regular, color: color(0xFFFFFF, 0.70), centerX: 320, top: 68)

// Soft wells under the two icons; the Finder labels sit on their lower part.
for x in [170.0, 470.0] {
    let well = NSBezierPath(roundedRect: NSRect(x: x - 92, y: 118, width: 184, height: 188), xRadius: 28, yRadius: 28)
    color(0xFFFFFF, 0.06).setFill()
    well.fill()
    color(0xFFFFFF, 0.10).setStroke()
    well.lineWidth = 1
    well.stroke()
}

// The arrow, green to amber like a charge rising to its limit.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 280, y: 200))
arrow.curve(to: NSPoint(x: 352, y: 200), controlPoint1: NSPoint(x: 305, y: 184), controlPoint2: NSPoint(x: 330, y: 184))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
let head = NSBezierPath()
head.move(to: NSPoint(x: 344, y: 186))
head.line(to: NSPoint(x: 362, y: 201))
head.line(to: NSPoint(x: 343, y: 213))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
let stroke = NSBezierPath()
stroke.append(arrow)
stroke.append(head)
context.cgContext.saveGState()
context.cgContext.setLineWidth(5)
context.cgContext.setLineCap(.round)
context.cgContext.setLineJoin(.round)
context.cgContext.addPath(stroke.cgPath)
context.cgContext.replacePathWithStrokedPath()
context.cgContext.clip()
NSGradient(colors: [color(0x5EE08D), color(0xFFC84D)])!.draw(in: NSRect(x: 270, y: 170, width: 100, height: 60), angle: 0)
context.cgContext.restoreGState()

// First-launch hint: the app isn't notarised, so Gatekeeper asks once.
text("Ouverture bloquée ? Réglages Système › Confidentialité et sécurité › Ouvrir quand même",
     size: 11, weight: .regular, color: color(0xFFFFFF, 0.55), centerX: 320, top: 366)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
