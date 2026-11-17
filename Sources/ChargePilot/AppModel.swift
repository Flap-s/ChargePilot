import AppKit
import Combine
import Foundation
import ChargePilotCore
import ServiceManagement
import UserNotifications

enum MenuBarStyle: String, CaseIterable {
    case iconAndPercent, icon, percent

    var label: String {
        switch self {
        case .iconAndPercent: return "Icône et pourcentage"
        case .icon: return "Icône seule"
        case .percent: return "Pourcentage seul"
        }
    }
}

enum HelperStatus: Equatable {
    case checking
    case notInstalled
    case unreachable(String)
    case outdated
    case running
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var battery = BatterySnapshot()
    @Published private(set) var helper = HelperState()
    @Published private(set) var helperStatus: HelperStatus = .checking
    /// Settings as edited in the app; pushed to the helper shortly after each change.
    @Published var config = ChargeConfig() {
        didSet { if config != oldValue, !applyingRemote { scheduleConfigPush() } }
    }
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var highPowerMode = false
    @Published private(set) var nativeLimit: Int?
    @Published var lastError: String?
    @Published var busy = false

    let history = HistoryStore()
    let client = HelperClient()

    private var timer: Timer?
    private var pushTask: Task<Void, Never>?
    private var applyingRemote = false
    private var lastLocalEdit = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    private let defaults = UserDefaults.standard
    /// Notifications need an app bundle; a bare executable (swift run) would crash.
    private static let inBundle = Bundle.main.bundleIdentifier != nil

    var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .iconAndPercent }
        set { defaults.set(newValue.rawValue, forKey: "menuBarStyle"); objectWillChange.send() }
    }

    var notificationsEnabled: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications"); objectWillChange.send() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Ouverture à la connexion : \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    private init() {
        Self.importLegacyDefaults()
        battery = BatteryReader.read()
        nativeLimit = NativeChargeLimit.current()
        BatteryReader.observeChanges { [weak self] in
            Task { @MainActor in self?.refreshBattery() }
        }
        // A connection left over from before sleep can stay broken; start a fresh one on wake.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.client.invalidate()
                Task { await self?.refresh() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Notification permission is asked from the welcome window, alongside the other permissions.
        Task { await refresh() }
        readPowerMode()
    }

    /// Set when this copy of the app isn't signed as `app.chargepilot.ChargePilot`, which the helper requires.
    static let signatureProblem: String? = {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let staticCode = Optional(unsafeBitCast(code, to: SecStaticCode.self)),
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        else { return "Cette copie de ChargePilot n'est pas signée : l'assistant la refuse. Réinstallez ChargePilot." }
        guard identifier != ChargePilotIDs.appBundle else { return nil }
        return "Cette copie de ChargePilot est mal signée (identifiant « \(identifier) ») : l'assistant la refuse. Réinstallez ChargePilot."
    }()

    /// Brings over the preferences saved under Mesure, the app's former name, once.
    private static func importLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedLegacyDefaults"), let legacy = UserDefaults(suiteName: "app.mesure.Mesure") else { return }
        for key in ["menuBarStyle", "notifications", "settingsPane"] where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "importedLegacyDefaults")
    }

    // MARK: Refresh

    private func refreshBattery() {
        battery = BatteryReader.read()
        history.record(battery)
    }

    func refresh() async {
        refreshBattery()
        guard HelperInstaller.isInstalled else {
            helperStatus = .notInstalled
            return
        }
        do {
            let state = try await client.state(fromApp: true)
            helper = state
            helperStatus = HelperInstaller.needsUpdate ? .outdated : .running
            // Take the helper's settings unless the user is mid-edit (they may have changed from the CLI or a schedule).
            if pushTask == nil, Date().timeIntervalSince(lastLocalEdit) > 2, state.config != config {
                applyingRemote = true
                config = state.config
                applyingRemote = false
            }
            for event in state.events { notify(event) }
        } catch {
            helperStatus = .unreachable(Self.signatureProblem ?? error.localizedDescription)
        }
    }

    func refreshSlow() {
        nativeLimit = NativeChargeLimit.current()
        readPowerMode()
    }

    var status: ChargeStatus {
        switch helperStatus {
        case .notInstalled, .unreachable: return .notInstalled
        default: return helper.status
        }
    }

    var displayPercent: Int { battery.percent(hardware: config.useHardwarePercent) }

    /// The limit is held by cutting the adapter in a small band rather than by pausing charging.
    var alternatesPower: Bool {
        let caps = helper.capabilities
        guard !caps.canInhibitCharging, caps.canDisableAdapter else { return false }
        return config.sailing || !caps.nativeSteps.contains(config.limit)
    }

    // MARK: Settings

    private func scheduleConfigPush() {
        lastLocalEdit = Date()
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.client.setConfig(self.config)
            } catch {
                self.lastError = error.localizedDescription
            }
            self.pushTask = nil
            await self.refresh()
        }
    }

    // MARK: Commands

    func perform(_ command: HelperCommand, value: Int = 0) {
        Task {
            do {
                try await client.perform(command, value: value)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            await refresh()
            readPowerMode()
        }
    }

    func setLimit(_ limit: Int) {
        config.limit = min(max(limit, ChargeConfig.limitRange.lowerBound), ChargeConfig.limitRange.upperBound)
    }

    func setLowPowerMode(_ on: Bool) {
        perform(.lowPowerMode, value: on ? 1 : 0)
        lowPowerMode = on
    }

    func setHighPowerMode(_ on: Bool) {
        perform(.highPowerMode, value: on ? 1 : 0)
        highPowerMode = on
    }

    private func readPowerMode() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("powermode") }
        highPowerMode = line?.split(separator: " ").last == "2"
    }

    // MARK: Helper installation

    func installHelper() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try HelperInstaller.install()
                client.invalidate()
                lastError = nil
                // Give launchd a moment to start the daemon, then hand it the current settings on first install.
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func uninstallHelper() {
        Task {
            do {
                try HelperInstaller.uninstall()
                client.invalidate()
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func toggleCLI() {
        do {
            if HelperInstaller.cliInstalled { try HelperInstaller.uninstallCLI() } else { try HelperInstaller.installCLI() }
            objectWillChange.send()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func willQuit() {
        history.save()
        client.detachAppSync()
    }

    // MARK: Notifications

    private func notify(_ event: HelperEvent) {
        guard Self.inBundle, notificationsEnabled, let (title, body) = event.notification else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: URL scheme

    /// chargepilot://limit/80, chargepilot://topup, chargepilot://discharge/60, chargepilot://calibrate, chargepilot://cycle, chargepilot://cancel,
    /// chargepilot://pause, chargepilot://resume, chargepilot://lowpower/on, chargepilot://sailing/off
    func handle(_ url: URL) {
        guard url.scheme == "chargepilot", let host = url.host?.lowercased() else { return }
        let argument = url.pathComponents.dropFirst().first
        let number = argument.flatMap(Int.init)
        let flag = argument.map { ["on", "1", "true", "oui"].contains($0.lowercased()) }
        switch host {
        case "limit": if let number { setLimit(number) }
        case "topup": perform(.topUp)
        case "discharge": perform(.discharge, value: number ?? 0)
        case "calibrate": perform(.calibrate)
        case "cycle", "cycles": perform(.cycle)
        case "update": Task { await Updater.shared.checkAndInstall() }
        case "cancel": perform(.cancel)
        case "pause": perform(.pause)
        case "resume": perform(.resume)
        case "lowpower": setLowPowerMode(flag ?? !lowPowerMode)
        case "highpower": setHighPowerMode(flag ?? !highPowerMode)
        case "sailing": config.sailing = flag ?? !config.sailing
        case "heat": config.heatProtection = flag ?? !config.heatProtection
        default: lastError = "Lien inconnu : \(url.absoluteString)"
        }
    }
}
