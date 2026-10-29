import Foundation
import IOKit
import IOKit.ps

/// One reading of the battery and power adapter, taken from the IORegistry and the SMC.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var date = Date()
    public var present = false
    /// Percentage macOS shows in the menu bar.
    public var percent = 0
    /// Remaining charge over full charge capacity, without macOS's smoothing.
    public var hardwarePercent = 0.0
    public var isCharging = false
    public var externalConnected = false
    public var fullyCharged = false
    public var cycleCount = 0
    public var designCapacity = 0
    public var fullChargeCapacity = 0
    public var nominalCapacity = 0
    public var remainingCapacity = 0
    public var temperature: Double?
    public var voltage = 0.0
    public var amperage = 0.0
    public var cellVoltages: [Double] = []
    public var adapterName: String?
    public var adapterWatts: Int?
    public var adapterVoltage: Double?
    public var adapterCurrent: Double?
    /// Power drawn from the wall, in watts.
    public var systemPowerIn: Double?
    /// Power the computer consumes, in watts.
    public var systemLoad: Double?
    public var timeToEmpty: Int?
    public var timeToFull: Int?
    public var serial: String?
    public var notChargingReason: Int = 0

    public init() {}

    /// Positive while charging, negative while the battery supplies power.
    public var batteryPower: Double { voltage * amperage }

    /// Health as a percentage of design capacity.
    public var health: Double? {
        let capacity = nominalCapacity > 0 ? nominalCapacity : fullChargeCapacity
        guard designCapacity > 0, capacity > 0 else { return nil }
        return min(100, Double(capacity) / Double(designCapacity) * 100)
    }

    public func percent(hardware: Bool) -> Int {
        hardware ? Int(hardwarePercent.rounded(.down)) : percent
    }
}

public enum BatteryReader {
    public static func read(smc: SMC? = nil) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snapshot }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return snapshot }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        snapshot.present = bool(props["BatteryInstalled"]) ?? true
        snapshot.percent = int(props["CurrentCapacity"]) ?? 0
        snapshot.isCharging = bool(props["IsCharging"]) ?? false
        snapshot.externalConnected = bool(props["ExternalConnected"]) ?? false
        snapshot.fullyCharged = bool(props["FullyCharged"]) ?? false
        snapshot.cycleCount = int(props["CycleCount"]) ?? int(data["CycleCount"]) ?? 0
        snapshot.designCapacity = int(props["DesignCapacity"]) ?? int(data["DesignCapacity"]) ?? 0
        snapshot.fullChargeCapacity = int(props["AppleRawMaxCapacity"]) ?? int(data["FullChargeCapacity"]) ?? 0
        snapshot.nominalCapacity = int(props["NominalChargeCapacity"]) ?? int(data["NominalChargeCapacity"]) ?? 0
        snapshot.remainingCapacity = int(props["AppleRawCurrentCapacity"]) ?? int(data["RemainingCapacity"]) ?? 0
        if snapshot.fullChargeCapacity > 0 {
            snapshot.hardwarePercent = min(100, Double(snapshot.remainingCapacity) / Double(snapshot.fullChargeCapacity) * 100)
        } else {
            snapshot.hardwarePercent = Double(snapshot.percent)
        }
        snapshot.voltage = Double(int(props["Voltage"]) ?? 0) / 1000
        snapshot.amperage = Double(signed(props["InstantAmperage"]) ?? signed(props["Amperage"]) ?? 0) / 1000
        if let cells = data["CellVoltage"] as? [Any] {
            snapshot.cellVoltages = cells.compactMap(int).map { Double($0) / 1000 }
        }
        if let raw = int(props["Temperature"]) ?? int(props["VirtualTemperature"]) {
            snapshot.temperature = Double(raw) / 100
        }
        if let adapter = props["AdapterDetails"] as? [String: Any], snapshot.externalConnected {
            snapshot.adapterName = (adapter["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
                ?? adapter["Description"] as? String
            snapshot.adapterWatts = int(adapter["Watts"])
            snapshot.adapterVoltage = int(adapter["AdapterVoltage"]).map { Double($0) / 1000 }
            snapshot.adapterCurrent = int(adapter["Current"]).map { Double($0) / 1000 }
        }
        if let telemetry = props["PowerTelemetryData"] as? [String: Any] {
            snapshot.systemPowerIn = int(telemetry["SystemPowerIn"]).map { Double($0) / 1000 }
            snapshot.systemLoad = int(telemetry["SystemLoad"]).map { Double($0) / 1000 }
        }
        if !snapshot.externalConnected { snapshot.systemPowerIn = 0 }
        let empty = int(props["AvgTimeToEmpty"]) ?? 65535
        let full = int(props["AvgTimeToFull"]) ?? 65535
        snapshot.timeToEmpty = empty < 65535 && !snapshot.externalConnected ? empty : nil
        snapshot.timeToFull = full < 65535 && snapshot.isCharging ? full : nil
        snapshot.serial = props["Serial"] as? String
        if let charger = props["ChargerData"] as? [String: Any] {
            snapshot.notChargingReason = int(charger["NotChargingReason"]) ?? 0
        }

        // The SMC's battery thermistors are more reliable than the registry, which omits them on recent macOS.
        if let smc = smc ?? (try? SMC()) {
            let readings = ["TB0T", "TB1T", "TB2T"].compactMap { smc.read($0)?.number }.filter { $0 > 0 && $0 < 100 }
            if !readings.isEmpty { snapshot.temperature = readings.max() }
            if snapshot.cellVoltages.isEmpty {
                snapshot.cellVoltages = ["BC1V", "BC2V", "BC3V", "BC4V"].compactMap { smc.read($0)?.number }
                    .filter { $0 > 2000 && $0 < 5000 }.map { $0 / 1000 }
            }
        }
        return snapshot
    }

    /// Registers `handler` for power source changes (plugging, percentage changes) on the current run loop.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        final class Box { let handler: () -> Void; init(_ h: @escaping () -> Void) { handler = h } }
        let box = Unmanaged.passRetained(Box(handler))
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().handler()
        }, box.toOpaque())
        if let source { CFRunLoopAddSource(CFRunLoopGetCurrent(), source.takeRetainedValue(), .defaultMode) }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    /// Currents are reported as 64-bit two's complement values.
    private static func signed(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: number.int64Value)
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }
}
