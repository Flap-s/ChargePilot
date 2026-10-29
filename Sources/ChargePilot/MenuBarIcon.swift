import AppKit
import ChargePilotCore

/// Draws the menu bar battery: the charge level, a tick at the limit, and a glyph for what's happening.
enum MenuBarIcon {
    static func image(percent: Int, limit: Int, status: ChargeStatus) -> NSImage {
        let size = NSSize(width: 27, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 23, height: 12)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1
            NSColor.black.withAlphaComponent(0.45).setStroke()
            outline.stroke()

            let cap = NSBezierPath(roundedRect: NSRect(x: 24.5, y: 4, width: 2, height: 5), xRadius: 1, yRadius: 1)
            NSColor.black.withAlphaComponent(0.45).setFill()
            cap.fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            let level = CGFloat(min(max(percent, 0), 100)) / 100
            let fill = NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * level), height: inner.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()

            if limit < 100, status != .notInstalled, status != .disabled {
                let x = inner.minX + inner.width * CGFloat(limit) / 100
                // Cut the tick out of the fill so it reads on both sides.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(rect: NSRect(x: x - 0.75, y: body.minY - 0.5, width: 1.5, height: body.height + 1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(x: x - 0.5, y: body.minY - 1, width: 1, height: 3)).fill()
                NSBezierPath(rect: NSRect(x: x - 0.5, y: body.maxY - 2, width: 1, height: 3)).fill()
            }

            if let glyph = glyph(for: status) {
                let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .black)
                if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let rect = NSRect(
                        x: (body.midX - symbol.size.width / 2).rounded(), y: (body.midY - symbol.size.height / 2).rounded(),
                        width: symbol.size.width, height: symbol.size.height
                    )
                    let context = NSGraphicsContext.current
                    // Over the fill, cut the glyph out so the menu bar shows through it…
                    context?.saveGraphicsState()
                    NSBezierPath(rect: fill).setClip()
                    symbol.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                    context?.restoreGraphicsState()
                    // …and over the empty part, draw it solid.
                    context?.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: fill.maxX, y: body.minY, width: body.maxX - fill.maxX, height: body.height)).setClip()
                    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    context?.restoreGraphicsState()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func glyph(for status: ChargeStatus) -> String? {
        switch status {
        case .charging: return "bolt.fill"
        case .limitReached, .sailing: return "pause.fill"
        case .discharging: return "arrow.down"
        case .heatProtection: return "thermometer.medium"
        case .notInstalled: return "exclamationmark"
        case .full, .onBattery, .disabled: return nil
        }
    }
}
