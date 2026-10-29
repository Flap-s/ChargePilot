import Foundation
import IOKit.pwr_mgt
import ChargePilotCore
import os

let log = Logger(subsystem: ChargePilotIDs.helperLabel, category: "daemon")

// IOKit's power messages are C macros that Swift doesn't import.
private let messageCanSystemSleep: natural_t = 0xE000_0270
private let messageSystemWillSleep: natural_t = 0xE000_0280
private let messageSystemHasPoweredOn: natural_t = 0xE000_0300

/// The charge controller. Runs as root and keeps enforcing the limit whether or not the app is open.
/// Everything happens on the main queue.
final class Daemon {
    private let hardware: ChargeHardware
    private var config = ChargeConfig()
    private var policy = ChargePolicy()
    private var state = HelperState()
    private var events: [HelperEvent] = []
    private var lastAppSeen: Date?
    private var lastScheduleCheck = Date()
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var sleeping = false
    private var handedBack = false
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    private let directory = URL(fileURLWithPath: ChargePilotIDs.helperSupportDirectory)
    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var policyURL: URL { directory.appendingPathComponent("state.json") }

    /// How long the app counts as running after its last request.
    private static let appTimeout: TimeInterval = 20

    init(hardware: ChargeHardware) {
        self.hardware = hardware
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL), let saved = try? JSON.decoder.decode(ChargeConfig.self, from: data) {
            config = saved
        }
        if let data = try? Data(contentsOf: policyURL), let saved = try? JSON.decoder.decode(ChargePolicy.self, from: data) {
            policy = saved
        }
    }

    func start() {
        BatteryReader.observeChanges { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        registerForSleep()
        tick()
        log.info("ChargePilot helper \(ChargePilotBuild.helperRevision, privacy: .public) started; inhibit=\(self.hardware.capabilities.chargeInhibitKey ?? "none", privacy: .public) adapter=\(self.hardware.capabilities.adapterKey ?? "none", privacy: .public)")
    }

    private var appPresent: Bool {
        guard let lastAppSeen else { return false }
        return Date().timeIntervalSince(lastAppSeen) < Self.appTimeout
    }

    private var active: Bool { config.enabled && (config.limitWhenAppClosed || appPresent) }

    // MARK: Control loop

    func tick() {
        guard !sleeping else { return }
        runSchedules()
        let battery = BatteryReader.read(smc: hardware.smc)
        let before = policy
        let (decision, newEvents) = policy.evaluate(
            battery, config: config, capabilities: hardware.capabilities, active: active,
            adapterDisabled: hardware.adapterDisabled
        )
        var error: String?
        if active {
            handedBack = false
            error = hardware.setChargingInhibited(decision.inhibitCharging) ?? error
            error = hardware.setAdapterDisabled(decision.disableAdapter) ?? error
            hardware.setLED(decision.led)
            if let limit = decision.nativeLimit {
                if policy.savedNativeLimit == nil { policy.savedNativeLimit = hardware.nativeLimit ?? 100 }
                error = hardware.setNativeLimit(limit) ?? error
            }
        } else if !handedBack {
            // Paused: give charging back to macOS once, then leave the SMC alone.
            handBack()
            handedBack = true
        }
        setPreventSleep(active && decision.preventSleep)

        events.append(contentsOf: newEvents)
        if events.count > 50 { events.removeFirst(events.count - 50) }
        for event in newEvents { log.info("event \(event.kind.rawValue, privacy: .public) \(event.detail, privacy: .public)") }
        if policy != before { save() }

        state.config = config
        state.mode = policy.mode
        state.status = decision.status
        state.chargingInhibited = hardware.chargingInhibited
        state.adapterDisabled = hardware.adapterDisabled
        state.heatBlocked = policy.heatBlocked
        state.sailingHold = policy.sailingHold
        state.capabilities = hardware.capabilities
        state.lastCalibration = policy.lastCalibration
        state.lastError = error
        state.helperVersion = ChargePilotBuild.helperRevision
    }

    /// Restores the adapter, the LED and the native limit the user had before ChargePilot took over.
    private func handBack() {
        hardware.restore()
        if let saved = policy.savedNativeLimit {
            _ = hardware.setNativeLimit(saved)
            policy.savedNativeLimit = nil
        }
    }

    private func runSchedules() {
        let now = Date()
        defer { lastScheduleCheck = now }
        for item in ScheduleRunner.due(config.schedules, from: lastScheduleCheck, to: now) {
            log.info("schedule \(item.action.rawValue, privacy: .public)")
            switch item.action {
            case .topUp: _ = perform(.topUp, value: 0)
            case .discharge: _ = perform(.discharge, value: item.value)
            case .calibrate: _ = perform(.calibrate, value: 0)
            case .cycle: _ = perform(.cycle, value: 0)
            case .setLimit: _ = perform(.setLimit, value: item.value)
            case .pause: _ = perform(.pause, value: 0)
            case .resume: _ = perform(.resume, value: 0)
            }
            events.append(HelperEvent(.scheduleRan, item.action.rawValue))
        }
    }

    private func save() {
        if let data = try? JSON.encoder.encode(config) { try? data.write(to: configURL, options: .atomic) }
        if let data = try? JSON.encoder.encode(policy) { try? data.write(to: policyURL, options: .atomic) }
    }

    private func setPreventSleep(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ChargePilot : charge ou décharge en cours" as CFString, &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Requests

    func currentState(fromApp: Bool) -> HelperState {
        if fromApp {
            let wasPresent = appPresent
            lastAppSeen = Date()
            if !wasPresent { tick() }
        }
        var snapshot = state
        if fromApp {
            snapshot.events = events
            events.removeAll()
        }
        return snapshot
    }

    func detachApp() {
        lastAppSeen = nil
        tick()
    }

    func setConfig(_ new: ChargeConfig) {
        var new = new
        new.clamp()
        if new.limit != config.limit || new.sailing != config.sailing { policy.announcedTarget = false }
        config = new
        save()
        tick()
    }

    func perform(_ command: HelperCommand, value: Int) -> String? {
        let caps = hardware.capabilities
        switch command {
        case .topUp:
            policy.start(.topUp)
        case .discharge:
            guard caps.canDisableAdapter else { return "Ce Mac ne permet pas de couper l'adaptateur secteur" }
            let target = value > 0 ? value : config.limit
            policy.start(.discharge(target: min(max(target, 5), 100)))
        case .calibrate:
            guard caps.canDisableAdapter else { return "La calibration demande de pouvoir couper l'adaptateur secteur" }
            policy.startCalibration()
        case .cycle:
            guard caps.canDisableAdapter else { return "Les cycles demandent de pouvoir couper l'adaptateur secteur" }
            let battery = BatteryReader.read(smc: hardware.smc)
            guard battery.externalConnected || hardware.adapterDisabled else { return "Branchez le Mac pour lancer les cycles" }
            policy.startCycles(config: config, percent: battery.percent)
        case .cancel:
            policy.start(.normal)
        case .pause:
            config.enabled = false
        case .resume:
            config.enabled = true
        case .setLimit:
            guard ChargeConfig.limitRange.contains(value) else { return "Limite hors plage (20–100 %)" }
            config.limit = value
            policy.announcedTarget = false
        case .lowPowerMode:
            if let error = hardware.setLowPowerMode(value != 0) { return error }
        case .highPowerMode:
            if let error = hardware.setHighPowerMode(value != 0) { return error }
        }
        save()
        tick()
        return nil
    }

    func smcRead(_ key: String) -> String {
        guard FourCC.isValid(key) else { return "clé invalide" }
        do {
            let value = try hardware.smc.readThrowing(key)
            return "\(value.type) \(value.bytes.count) \(String(format: "%02x", value.attributes)) \(value.hex)"
        } catch {
            return "\(error)"
        }
    }

    func smcWrite(_ key: String, hex: String) -> String? {
        guard ChargeHardware.writableKeys.contains(key) else { return "Écriture refusée : \(key) n'est pas une clé de charge" }
        guard let bytes = [UInt8](hex: hex) else { return "hexadécimal invalide" }
        do { try hardware.smc.write(key, bytes) } catch { return "\(error)" }
        hardware.detect()
        return nil
    }

    func setHardwareOverride(_ data: Data) -> String? {
        if let error = hardware.setOverride(data) { return error }
        tick()
        return nil
    }

    func shutdown() {
        handBack()
        setPreventSleep(false)
        save()
    }

    // MARK: Sleep

    private func registerForSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue()
            daemon.handlePower(message: message, argument: argument)
        }, &notifier)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        }
    }

    private func handlePower(message: natural_t, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case messageSystemWillSleep:
            prepareForSleep()
            IOAllowPowerChange(rootPort, token)
        case messageSystemHasPoweredOn:
            sleeping = false
            tick()
        default:
            break
        }
    }

    /// Nothing runs while the Mac sleeps, so leave the hardware in a state that's safe for hours.
    private func prepareForSleep() {
        sleeping = true
        guard active else { return }
        let battery = BatteryReader.read(smc: hardware.smc)
        let percent = battery.percent(hardware: config.useHardwarePercent)
        // A cut adapter would drain the battery all night.
        if hardware.adapterDisabled { _ = hardware.setAdapterDisabled(false) }
        let nearLimit = percent >= config.limit - 1 && policy.mode == .normal && config.limit < 100
        if config.stopChargingWhenSleeping || nearLimit || policy.mode != .normal && policy.mode != .topUp {
            _ = hardware.setChargingInhibited(true)
        }
        if config.ledOffWhileSleeping { hardware.setLED(.off) }
        log.info("sleep: inhibited=\(self.hardware.chargingInhibited)")
    }
}
