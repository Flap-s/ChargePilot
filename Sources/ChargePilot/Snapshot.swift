import AppKit
import ChargePilotCore
import SwiftUI

/// `ChargePilot --snapshot <directory>` renders the menu and settings to PNG files, to review the layout without clicking around.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        Task { @MainActor in
            await model.refresh()
            render(PopoverView().environmentObject(model), to: directory.appendingPathComponent("menu.png"))
            render(SettingsView().frame(width: 780, height: 560).environmentObject(model).environmentObject(model.history),
                   to: directory.appendingPathComponent("settings.png"))
            let tabs: [(String, AnyView)] = [
                ("general", AnyView(GeneralSettings())), ("charge", AnyView(ChargeSettings())), ("tasks", AnyView(TasksSettings())), ("led", AnyView(LEDSettings())),
                ("schedule", AnyView(ScheduleSettings())), ("battery", AnyView(BatteryInfoView())), ("helper", AnyView(HelperSettings())), ("updates", AnyView(UpdateSettings())),
            ]
            for (name, view) in tabs {
                render(view.frame(width: 600, height: 520).environmentObject(model).environmentObject(model.history),
                       to: directory.appendingPathComponent("settings-\(name).png"))
            }
            renderIcons(to: directory.appendingPathComponent("icons.png"))
            render(WelcomeView().environmentObject(model), to: directory.appendingPathComponent("welcome.png"))
            exit(0)
        }
    }

    /// Every icon state at 8×, on a dark and a light menu bar, tinted the way macOS tints template images.
    private static func renderIcons(to url: URL) {
        let states: [(Int, ChargeStatus)] = [(80, .charging), (35, .charging), (80, .limitReached), (60, .discharging), (95, .full), (50, .heatProtection)]
        let scale: CGFloat = 8
        let cell = NSSize(width: 34 * scale, height: 20 * scale)
        let image = NSImage(size: NSSize(width: cell.width * CGFloat(states.count), height: cell.height * 2), flipped: false) { _ in
            for (row, dark) in [true, false].enumerated() {
                for (column, state) in states.enumerated() {
                    let origin = NSPoint(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
                    (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
                    NSRect(origin: origin, size: cell).fill()
                    let icon = MenuBarIcon.image(percent: state.0, limit: 80, status: state.1)
                    let tinted = NSImage(size: icon.size, flipped: false) { rect in
                        icon.draw(in: rect)
                        (dark ? NSColor.white : NSColor.black).set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: origin.x + 3 * scale, y: origin.y + 3 * scale, width: icon.size.width * scale, height: icon.size.height * scale))
                }
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
