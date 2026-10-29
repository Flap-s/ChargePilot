import Foundation

public enum LEDColor: String, Codable, Sendable {
    case system, off, green, amber
}

/// What the hardware should do after one evaluation.
public struct ChargeDecision: Equatable, Sendable {
    public var inhibitCharging = false
    public var disableAdapter = false
    public var status: ChargeStatus = .onBattery
    public var led: LEDColor = .system
    /// Keep the Mac from idle-sleeping (charging to the limit, or a discharge in progress).
    public var preventSleep = false
    /// macOS's own charge limit to set (100 turns it off); nil leaves it alone.
    public var nativeLimit: Int?
}

/// The charge-limiting logic, free of I/O so it can be tested.
public struct ChargePolicy: Codable, Equatable, Sendable {
    public var mode: ChargeMode = .normal
    public var sailingHold = false
    public var heatBlocked = false
    public var lastCalibration: Date?
    /// Set once a "limit reached" or "full" event fired, so it fires once per charge.
    public var announcedTarget = false
    /// macOS's charge limit before ChargePilot took it over, restored when ChargePilot hands charging back.
    public var savedNativeLimit: Int?
    /// When the adapter was last seen missing; macOS briefly reports it gone after it's turned back on.
    public var unpluggedSince: Date?

    public init() {}

    /// Margin (°C) under the heat threshold before charging resumes.
    public static let heatHysteresis = 2.0
    /// Width of the band the adapter cycles through on Macs that can only cut the adapter.
    public static let emulationBand = 2
    /// How long the adapter must stay missing before cycles count the Mac as unplugged.
    public static let unplugGrace: TimeInterval = 30

    public mutating func evaluate(
        _ battery: BatterySnapshot,
        config: ChargeConfig,
        capabilities: HardwareCapabilities,
        active: Bool,
        adapterDisabled: Bool = false,
        now: Date = Date()
    ) -> (ChargeDecision, [HelperEvent]) {
        var events: [HelperEvent] = []
        var decision = ChargeDecision()
        let percent = battery.percent(hardware: config.useHardwarePercent)
        // With the adapter cut, macOS may report it as unplugged; it is still there.
        var battery = battery
        battery.externalConnected = battery.externalConnected || adapterDisabled
        let plugged = battery.externalConnected
        // After a task ends, decide again under the new mode, keeping the events raised so far.
        func reevaluate() -> (ChargeDecision, [HelperEvent]) {
            let (decision, more) = evaluate(battery, config: config, capabilities: capabilities, active: active, adapterDisabled: adapterDisabled, now: now)
            return (decision, events + more)
        }

        guard active, battery.present else {
            decision.status = .disabled
            decision.led = .system
            return (decision, events)
        }

        // Unplugging ends a top-up or cycles: the next charge goes back to the limit.
        if !plugged, mode == .topUp { mode = .normal; announcedTarget = false }
        if plugged { unpluggedSince = nil } else if unpluggedSince == nil { unpluggedSince = now }
        if !plugged, case .cycle = mode, now.timeIntervalSince(unpluggedSince ?? now) >= Self.unplugGrace {
            mode = .normal
            announcedTarget = false
            events.append(HelperEvent(.cycleStopped))
        }

        updateHeat(battery, config: config, events: &events)

        switch mode {
        case .topUp:
            decision.inhibitCharging = heatBlocked
            if percent >= 100, battery.fullyCharged || !battery.isCharging {
                decision.status = .full
                if !announcedTarget { events.append(HelperEvent(.topUpDone)); announcedTarget = true }
            } else {
                decision.status = heatBlocked ? .heatProtection : (plugged ? .charging : .onBattery)
            }

        case .discharge(let target):
            if percent > target, capabilities.canDisableAdapter {
                decision.inhibitCharging = true
                decision.disableAdapter = plugged
                decision.status = .discharging
                decision.preventSleep = plugged
            } else {
                mode = .normal
                events.append(HelperEvent(.dischargeDone, "\(percent)"))
                return reevaluate()
            }

        case .calibration(let phase, let since):
            decision.preventSleep = plugged
            switch phase {
            case .dischargeLow:
                if percent > config.calibrationLowPercent {
                    decision.inhibitCharging = true
                    decision.disableAdapter = plugged && capabilities.canDisableAdapter
                    decision.status = .discharging
                } else {
                    advance(to: .chargeFull, now: now, events: &events)
                    return reevaluate()
                }
            case .chargeFull:
                if percent >= 100, plugged, battery.fullyCharged || !battery.isCharging {
                    advance(to: .holdFull, now: now, events: &events)
                    return reevaluate()
                }
                decision.status = plugged ? .charging : .onBattery
            case .holdFull:
                decision.status = .full
                if now.timeIntervalSince(since) >= Double(config.calibrationHoldMinutes) * 60 {
                    advance(to: .dischargeToLimit, now: now, events: &events)
                    return reevaluate()
                }
            case .dischargeToLimit:
                if percent > config.limit, config.limit < 100, capabilities.canDisableAdapter {
                    decision.inhibitCharging = true
                    decision.disableAdapter = plugged
                    decision.status = .discharging
                } else {
                    mode = .normal
                    lastCalibration = now
                    announcedTarget = true
                    events.append(HelperEvent(.calibrationDone))
                    return reevaluate()
                }
            }

        case .cycle(let low, let high, let draining, let count):
            // Cycles follow the percentage macOS shows, the one its own limit (the backstop) uses too.
            let shown = battery.percent
            if draining {
                if shown > low, capabilities.canDisableAdapter {
                    decision.inhibitCharging = true
                    decision.disableAdapter = true
                    decision.status = .discharging
                } else {
                    mode = .cycle(low: low, high: high, draining: false, count: count)
                    events.append(HelperEvent(.cycleCharge, "\(shown)"))
                    return reevaluate()
                }
            } else if shown >= high || (shown >= high - 2 && !battery.isCharging && battery.fullyCharged) {
                mode = .cycle(low: low, high: high, draining: true, count: count + 1)
                events.append(HelperEvent(.cycleDrain, "\(shown)"))
                return reevaluate()
            } else {
                decision.inhibitCharging = heatBlocked
                decision.status = heatBlocked ? .heatProtection : (plugged ? .charging : .onBattery)
            }

        case .normal:
            decision = normalDecision(percent: percent, battery: battery, config: config, capabilities: capabilities, events: &events)
        }

        decision.led = ledColor(for: decision, plugged: plugged, mode: config.magSafeLED)
        decision.nativeLimit = nativeLimit(config: config, capabilities: capabilities)
        if !plugged {
            decision.disableAdapter = false
            decision.preventSleep = false
        }
        return (decision, events)
    }

    private mutating func normalDecision(
        percent: Int,
        battery: BatterySnapshot,
        config: ChargeConfig,
        capabilities: HardwareCapabilities,
        events: inout [HelperEvent]
    ) -> ChargeDecision {
        var decision = ChargeDecision()
        let plugged = battery.externalConnected
        let limit = config.limit

        if !plugged {
            decision.status = .onBattery
            // A new charge starts once the battery falls below the limit again.
            if percent < limit { announcedTarget = false; sailingHold = false }
            return decision
        }

        if limit >= 100 {
            decision.inhibitCharging = heatBlocked
            decision.status = heatBlocked ? .heatProtection : (percent >= 100 ? .full : .charging)
            if percent < 100 { announcedTarget = false }
            return decision
        }

        // macOS's own limit holds the charge without cycling the battery, but only at its own steps.
        let nativeHolds = capabilities.nativeSteps.contains(limit) && !config.sailing
        // Once the limit is reached, hold until the charge falls below the band: zero by default (percent steps give
        // enough hysteresis), the sailing gap when sailing, or a small band on Macs that can only cut the adapter.
        let band = config.sailing ? config.sailingGap : (capabilities.canInhibitCharging || nativeHolds ? 0 : Self.emulationBand)
        if percent >= limit {
            sailingHold = true
        } else if percent < limit - band {
            sailingHold = false
        }

        if capabilities.canInhibitCharging {
            decision.inhibitCharging = sailingHold || heatBlocked
        } else if nativeHolds {
            decision.disableAdapter = heatBlocked && percent > 20 && capabilities.canDisableAdapter
        } else if capabilities.canDisableAdapter {
            decision.disableAdapter = sailingHold || (heatBlocked && percent > 20)
        }

        if config.automaticDischarge, percent > limit, capabilities.canDisableAdapter {
            decision.inhibitCharging = capabilities.canInhibitCharging
            decision.disableAdapter = true
            decision.status = .discharging
            return decision
        }

        if heatBlocked, percent < limit {
            decision.status = .heatProtection
        } else if decision.disableAdapter, percent > limit {
            // Running on battery down to a limit below the current charge.
            decision.status = .discharging
        } else if sailingHold {
            decision.status = percent >= limit ? .limitReached : .sailing
            if percent >= limit, !announcedTarget {
                events.append(HelperEvent(.limitReached, "\(limit)"))
                announcedTarget = true
            }
        } else {
            decision.status = .charging
            decision.preventSleep = config.preventSleepUntilLimit
            if percent < limit - 1 { announcedTarget = false }
        }
        return decision
    }

    /// The native limit to set: off while charging to full, otherwise the smallest step at or above the limit,
    /// which holds the limit exactly when it is a step and caps any overshoot (during sleep, for instance) otherwise.
    private func nativeLimit(config: ChargeConfig, capabilities: HardwareCapabilities) -> Int? {
        let steps = capabilities.nativeSteps
        guard !steps.isEmpty else { return nil }
        func ceiling(_ value: Int) -> Int { value >= 100 ? 100 : steps.first { $0 >= value } ?? 100 }
        switch mode {
        case .topUp: return 100
        case .discharge: return ceiling(config.limit)
        case .calibration(let phase, _):
            switch phase {
            case .dischargeLow: return steps.first
            case .chargeFull, .holdFull: return 100
            case .dischargeToLimit: return ceiling(config.limit)
            }
        case .cycle(_, let high, _, _): return ceiling(high)
        case .normal: return ceiling(config.limit)
        }
    }

    private mutating func updateHeat(_ battery: BatterySnapshot, config: ChargeConfig, events: inout [HelperEvent]) {
        guard config.heatProtection, let temperature = battery.temperature else {
            heatBlocked = false
            return
        }
        if heatBlocked, temperature <= config.heatThreshold - Self.heatHysteresis {
            heatBlocked = false
            events.append(HelperEvent(.heatResumed, String(format: "%.1f", temperature)))
        } else if !heatBlocked, temperature >= config.heatThreshold, battery.externalConnected {
            heatBlocked = true
            events.append(HelperEvent(.heatPaused, String(format: "%.1f", temperature)))
        }
    }

    private mutating func advance(to phase: CalibrationPhase, now: Date, events: inout [HelperEvent]) {
        mode = .calibration(phase: phase, since: now)
        events.append(HelperEvent(.calibrationPhase, phase.rawValue))
    }

    private func ledColor(for decision: ChargeDecision, plugged: Bool, mode: MagSafeLEDMode) -> LEDColor {
        switch mode {
        case .system: return .system
        case .off: return .off
        case .green: return .green
        case .amber: return .amber
        case .automatic:
            guard plugged else { return .system }
            if decision.disableAdapter { return .off }
            switch decision.status {
            case .charging, .heatProtection: return .amber
            case .limitReached, .sailing, .full: return .green
            default: return .system
            }
        }
    }

    // MARK: Commands

    public mutating func start(_ newMode: ChargeMode) {
        mode = newMode
        announcedTarget = false
        sailingHold = false
    }

    public mutating func startCalibration(now: Date = Date()) {
        start(.calibration(phase: .dischargeLow, since: now))
    }

    /// Starts on battery when above the low bound, otherwise by charging.
    public mutating func startCycles(config: ChargeConfig, percent: Int) {
        start(.cycle(low: config.cycleLow, high: config.cycleHigh, draining: percent > config.cycleLow, count: 0))
    }
}
