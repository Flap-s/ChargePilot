import AppKit
import ChargePilotCore
import SwiftUI

@main
struct ChargePilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Réglages de ChargePilot", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.history)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let percent = model.displayPercent
        let icon = MenuBarIcon.image(percent: percent, limit: model.config.limit, status: model.status)
        switch model.menuBarStyle {
        case .icon:
            Image(nsImage: icon)
        case .percent:
            Text("\(percent) %")
        case .iconAndPercent:
            HStack(spacing: 4) {
                Text("\(percent) %")
                Image(nsImage: icon)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.runIfRequested()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        _ = AppModel.shared
        Updater.shared.startAutomaticChecks()
        if Updater.shared.consumeJustUpdated() {
            // The update may ship a newer helper: offer to install it now rather than waiting for the banner.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if HelperInstaller.needsUpdate { AppModel.shared.installHelper() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshSlow() }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        Task { @MainActor in AppModel.shared.handle(url) }
    }

    /// Quits synchronously: `terminate` may be called from a main-actor task (the updater), which would deadlock
    /// waiting for another main-actor task to reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.willQuit() }
        return .terminateNow
    }
}
