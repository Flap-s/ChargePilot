import Foundation

public enum ChargePilotIDs {
    public static let appBundle = "app.chargepilot.ChargePilot"
    public static let cliIdentifier = "app.chargepilot.cli"
    public static let helperLabel = "app.chargepilot.helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/app.chargepilot.helper"
    public static let helperPlistPath = "/Library/LaunchDaemons/app.chargepilot.helper.plist"
    public static let helperSupportDirectory = "/Library/Application Support/ChargePilot"
}

public enum MagSafeLEDMode: String, Codable, CaseIterable, Sendable {
    /// macOS drives the LED.
    case system
    /// Green once the limit holds, amber while charging, off while discharging.
    case automatic
    case off
    case green
    case amber
}

public enum ScheduledAction: String, Codable, CaseIterable, Sendable {
    case topUp, discharge, calibrate, cycle, setLimit, pause, resume
}

public struct ScheduleItem: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var action: ScheduledAction = .topUp
    /// Limit for `.setLimit`, target for `.discharge`.
    public var value = 80
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty means every day.
    public var weekdays: Set<Int> = []
    public var hour = 8
    public var minute = 0

    public init() {}
}

/// Settings the helper enforces. Saved by the helper so they hold while the app is closed.
public struct ChargeConfig: Codable, Equatable, Sendable {
    /// When false, ChargePilot leaves charging to macOS.
    public var enabled = true
    public var limit = 80
    public var sailing = false
    public var sailingGap = 5
    public var heatProtection = false
    public var heatThreshold = 35.0
    /// Use the battery's own percentage rather than the one macOS shows.
    public var useHardwarePercent = false
    /// Discharge on adapter power when the charge sits above the limit.
    public var automaticDischarge = false
    public var stopChargingWhenSleeping = false
    public var preventSleepUntilLimit = false
    /// Keep limiting after the app quits. When false the helper hands charging back to macOS while the app is closed.
    public var limitWhenAppClosed = true
    public var magSafeLED: MagSafeLEDMode = .automatic
    public var ledOffWhileSleeping = false
    public var calibrationHoldMinutes = 60
    public var calibrationLowPercent = 15
    /// Cycle mode (for a Mac that stays on a dock): run on battery down to `cycleLow`, then charge to `cycleHigh`, and repeat.
    public var cycleLow = 30
    public var cycleHigh = 85
    public var schedules: [ScheduleItem] = []

    public init() {}

    public static let limitRange = 20...100

    public mutating func clamp() {
        limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        sailingGap = min(max(sailingGap, 1), 30)
        heatThreshold = min(max(heatThreshold, 25), 50)
        calibrationHoldMinutes = min(max(calibrationHoldMinutes, 0), 240)
        calibrationLowPercent = min(max(calibrationLowPercent, 5), 50)
        cycleLow = min(max(cycleLow, 10), 80)
        cycleHigh = min(max(cycleHigh, cycleLow + 10), 100)
    }

    // Decode leniently so settings written by older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChargeConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        sailing = try c.decodeIfPresent(Bool.self, forKey: .sailing) ?? d.sailing
        sailingGap = try c.decodeIfPresent(Int.self, forKey: .sailingGap) ?? d.sailingGap
        heatProtection = try c.decodeIfPresent(Bool.self, forKey: .heatProtection) ?? d.heatProtection
        heatThreshold = try c.decodeIfPresent(Double.self, forKey: .heatThreshold) ?? d.heatThreshold
        useHardwarePercent = try c.decodeIfPresent(Bool.self, forKey: .useHardwarePercent) ?? d.useHardwarePercent
        automaticDischarge = try c.decodeIfPresent(Bool.self, forKey: .automaticDischarge) ?? d.automaticDischarge
        stopChargingWhenSleeping = try c.decodeIfPresent(Bool.self, forKey: .stopChargingWhenSleeping) ?? d.stopChargingWhenSleeping
        preventSleepUntilLimit = try c.decodeIfPresent(Bool.self, forKey: .preventSleepUntilLimit) ?? d.preventSleepUntilLimit
        limitWhenAppClosed = try c.decodeIfPresent(Bool.self, forKey: .limitWhenAppClosed) ?? d.limitWhenAppClosed
        magSafeLED = (try? c.decodeIfPresent(MagSafeLEDMode.self, forKey: .magSafeLED)) ?? d.magSafeLED
        ledOffWhileSleeping = try c.decodeIfPresent(Bool.self, forKey: .ledOffWhileSleeping) ?? d.ledOffWhileSleeping
        calibrationHoldMinutes = try c.decodeIfPresent(Int.self, forKey: .calibrationHoldMinutes) ?? d.calibrationHoldMinutes
        calibrationLowPercent = try c.decodeIfPresent(Int.self, forKey: .calibrationLowPercent) ?? d.calibrationLowPercent
        cycleLow = try c.decodeIfPresent(Int.self, forKey: .cycleLow) ?? d.cycleLow
        cycleHigh = try c.decodeIfPresent(Int.self, forKey: .cycleHigh) ?? d.cycleHigh
        schedules = (try? c.decodeIfPresent([ScheduleItem].self, forKey: .schedules)) ?? d.schedules
    }
}

public enum CalibrationPhase: String, Codable, Sendable {
    case dischargeLow, chargeFull, holdFull, dischargeToLimit
}

/// A one-off task that temporarily overrides the limit.
public enum ChargeMode: Codable, Equatable, Sendable {
    case normal
    case topUp
    case discharge(target: Int)
    case calibration(phase: CalibrationPhase, since: Date)
    /// Alternates running on battery down to `low` and charging up to `high` until unplugged or cancelled.
    case cycle(low: Int, high: Int, draining: Bool, count: Int)
}

/// What the helper is doing right now, for display.
public enum ChargeStatus: String, Codable, Sendable {
    case onBattery
    case charging
    case limitReached
    case sailing
    case discharging
    case heatProtection
    case full
    case disabled
    case notInstalled
}

/// Which SMC switches this Mac offers.
public struct HardwareCapabilities: Codable, Equatable, Sendable {
    public var chargeInhibitKey: String?
    public var adapterKey: String?
    public var magSafeLED = false
    public var lowPowerMode = true
    public var highPowerMode = false
    /// Limits macOS's own charge limit accepts (100 = off); nil when there is none.
    public var nativeLimitSteps: [Int]?

    public init() {}

    public var nativeSteps: [Int] { nativeLimitSteps ?? [] }

    public var canInhibitCharging: Bool { chargeInhibitKey != nil }
    public var canDisableAdapter: Bool { adapterKey != nil }
}

public struct HelperState: Codable, Equatable, Sendable {
    public var config = ChargeConfig()
    public var mode: ChargeMode = .normal
    public var status: ChargeStatus = .disabled
    public var chargingInhibited = false
    public var adapterDisabled = false
    public var heatBlocked = false
    public var sailingHold = false
    public var capabilities = HardwareCapabilities()
    public var lastCalibration: Date?
    public var lastError: String?
    public var helperVersion = ""
    /// Events since the app last asked, used for notifications.
    public var events: [HelperEvent] = []

    public init() {}
}

public struct HelperEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case limitReached, topUpDone, dischargeDone, calibrationPhase, calibrationDone, heatPaused, heatResumed, scheduleRan
        case cycleDrain, cycleCharge, cycleStopped
    }
    public var kind: Kind
    public var detail: String
    public var date = Date()

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }
}

/// Commands accepted by the helper's `perform` call.
public enum HelperCommand: String, Sendable, CaseIterable {
    case topUp, discharge, calibrate, cycle, cancel, pause, resume, setLimit, lowPowerMode, highPowerMode
}

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
