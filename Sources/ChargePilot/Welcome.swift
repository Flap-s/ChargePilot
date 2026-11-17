import AppKit
import ChargePilotCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// The window shown on first launch: moves the app into Applications and asks for what ChargePilot needs.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    static let completedKey = "welcomeCompleted"

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: completedKey) }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: WelcomeView().environmentObject(AppModel.shared))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Bienvenue dans ChargePilot"
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
        window = nil
    }
}

/// Where the app runs from, and moving it into Applications.
enum AppLocation {
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(user + "/")
    }

    /// Copies this app into /Applications (replacing an older copy, which goes to the Trash), then relaunches from there.
    static func moveToApplications() throws {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/ChargePilot.app")
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            throw UpdateError.message("Le dossier Applications n'est pas modifiable avec ce compte. Glissez ChargePilot dans Applications depuis le Finder.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        // The copy no longer comes from the internet as far as Gatekeeper is concerned: it was approved to run here.
        _ = try? UpdateInstaller.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The state of each permission, refreshed while the window is open (the user may change them in System Settings).
@MainActor
final class WelcomeModel: ObservableObject {
    enum NotificationState { case unknown, notAsked, allowed, denied }

    @Published var notifications: NotificationState = .unknown
    @Published var loginItem: SMAppService.Status = SMAppService.mainApp.status
    @Published var inApplications = AppLocation.isInApplications
    @Published var moveError: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        loginItem = SMAppService.mainApp.status
        inApplications = AppLocation.isInApplications
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: NotificationState = switch settings.authorizationStatus {
            case .notDetermined: .notAsked
            case .denied: .denied
            default: .allowed
            }
            Task { @MainActor in self.notifications = state }
        }
    }

    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if notifications == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func enableLoginItem() {
        if loginItem == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        try? SMAppService.mainApp.register()
        refresh()
    }

    func move() {
        do { try AppLocation.moveToApplications() } catch { moveError = error.localizedDescription }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = WelcomeModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                if !model.inApplications {
                    PermissionRow(
                        icon: "folder.fill", tint: .blue, title: "Dossier Applications",
                        detail: "ChargePilot doit vivre dans Applications pour se mettre à jour et garder son assistant.",
                        state: .action("Déplacer"), action: model.move
                    )
                    if let error = model.moveError {
                        Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                PermissionRow(
                    icon: "lock.shield.fill", tint: .green, title: "Assistant de charge",
                    detail: "Le service système qui suspend la charge à la limite. Votre mot de passe est demandé une seule fois.",
                    state: helperState, action: app.installHelper
                )
                PermissionRow(
                    icon: "bell.badge.fill", tint: .orange, title: "Notifications",
                    detail: "Pour savoir quand la limite est atteinte, qu'une tâche se termine ou que la batterie chauffe.",
                    state: notificationState, action: model.requestNotifications
                )
                PermissionRow(
                    icon: "power.circle.fill", tint: .purple, title: "Ouverture à la connexion",
                    detail: "Pour retrouver ChargePilot dans la barre des menus après un redémarrage.",
                    state: loginState, action: model.enableLoginItem
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Spacer(minLength: 18)

            HStack {
                Text("Ces choix se modifient ensuite dans Réglages.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(helperReady ? "Commencer" : "Plus tard") { WelcomeWindow.finish() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(helperReady ? .green : .gray)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 540, height: model.inApplications ? 560 : 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.19, blue: 0.23), Color(red: 0.04, green: 0.10, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.green.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 260)
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                Text("Bienvenue dans ChargePilot")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Quelques autorisations pour que ChargePilot prenne soin de votre batterie.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 22)
        }
        .frame(height: 210)
    }

    private var helperReady: Bool { app.helperStatus == .running }

    private var helperState: PermissionRow.State {
        switch app.helperStatus {
        case .running: return .done("Installé")
        case .outdated: return .action("Mettre à jour")
        case .checking: return .waiting
        case .notInstalled, .unreachable: return app.busy ? .waiting : .action("Installer")
        }
    }

    private var notificationState: PermissionRow.State {
        switch model.notifications {
        case .allowed: return .done("Autorisées")
        case .denied: return .action("Ouvrir Réglages")
        case .notAsked: return .action("Autoriser")
        case .unknown: return .waiting
        }
    }

    private var loginState: PermissionRow.State {
        switch model.loginItem {
        case .enabled: return .done("Activée")
        case .requiresApproval: return .action("Approuver")
        default: return .action("Activer")
        }
    }
}

struct PermissionRow: View {
    enum State: Equatable {
        case done(String)
        case action(String)
        case waiting
    }

    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .done(let label):
                Label(label, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .action(let label):
                Button(label, action: action).controlSize(.regular)
            case .waiting:
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
