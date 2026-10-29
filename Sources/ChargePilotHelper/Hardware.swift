import Foundation
import ChargePilotCore

/// An SMC switch: the key and the bytes that turn it on and off.
struct SMCSwitch: Codable {
    var keys: [String]
    var on: String
    var off: String

    var onBytes: [UInt8] { [UInt8](hex: on) ?? [] }
    var offBytes: [UInt8] { [UInt8](hex: off) ?? [] }
}

/// Optional `/Library/Application Support/ChargePilot/hardware.json`, to support firmware the built-in table doesn't know.
struct HardwareOverride: Codable {
    var chargeInhibit: SMCSwitch?
    var adapter: SMCSwitch?
}

/// Drives the SMC switches for charging, the power adapter and the MagSafe LED.
final class ChargeHardware {
    let smc: SMC
    private(set) var capabilities = HardwareCapabilities()
    private var inhibit: SMCSwitch?
    private var adapter: SMCSwitch?
    private var lastLED: LEDColor?
    private let native = NativeChargeLimitController()

    /// Known switches, most recent firmware first.
    private static let inhibitCandidates = [
        SMCSwitch(keys: ["CHTE"], on: "01000000", off: "00000000"),
        SMCSwitch(keys: ["CH0B", "CH0C"], on: "02", off: "00"),
    ]
    private static let adapterCandidates = [
        SMCSwitch(keys: ["CHIE"], on: "08", off: "00"),
        SMCSwitch(keys: ["CH0J"], on: "01", off: "00"),
        SMCSwitch(keys: ["CH0I"], on: "01", off: "00"),
    ]

    /// Keys the diagnostics command may write.
    static let writableKeys: Set<String> = ["CHTE", "CH0B", "CH0C", "CH0I", "CH0J", "CHIE", "ACLC", "CHLT", "CHWA"]

    init(smc: SMC) {
        self.smc = smc
        detect()
    }

    func detect() {
        let override = Self.loadOverride()
        inhibit = override?.chargeInhibit ?? Self.inhibitCandidates.first { usable($0) }
        adapter = override?.adapter ?? Self.adapterCandidates.first { usable($0) }
        capabilities.chargeInhibitKey = inhibit?.keys.joined(separator: "+")
        capabilities.adapterKey = adapter?.keys.joined(separator: "+")
        capabilities.magSafeLED = smc.exists("ACLC")
        capabilities.nativeLimitSteps = native?.steps
        let settings = (Self.run("/usr/bin/pmset", ["-g"]) ?? "").split(separator: "\n")
            .compactMap { $0.split(separator: " ").first.map(String.init) }
        capabilities.lowPowerMode = settings.contains("lowpowermode")
        capabilities.highPowerMode = settings.contains("powermode")
    }

    private func usable(_ candidate: SMCSwitch) -> Bool {
        candidate.keys.allSatisfy { key in
            guard let value = smc.read(key) else { return false }
            return value.bytes.count == candidate.onBytes.count
        }
    }

    private static let overrideURL = URL(fileURLWithPath: ChargePilotIDs.helperSupportDirectory).appendingPathComponent("hardware.json")

    private static func loadOverride() -> HardwareOverride? {
        guard let data = try? Data(contentsOf: overrideURL) else { return nil }
        return try? JSONDecoder().decode(HardwareOverride.self, from: data)
    }

    /// Saves (or, given no data, removes) the override and re-detects. Only charge keys are accepted.
    func setOverride(_ data: Data) -> String? {
        restore()
        if data.isEmpty {
            try? FileManager.default.removeItem(at: Self.overrideURL)
        } else {
            guard let override = try? JSONDecoder().decode(HardwareOverride.self, from: data) else { return "JSON invalide" }
            for sw in [override.chargeInhibit, override.adapter].compactMap({ $0 }) {
                guard sw.keys.allSatisfy(Self.writableKeys.contains), !sw.onBytes.isEmpty, sw.onBytes.count == sw.offBytes.count else {
                    return "Clés ou valeurs refusées"
                }
            }
            do { try data.write(to: Self.overrideURL, options: .atomic) } catch { return "\(error)" }
        }
        detect()
        return nil
    }

    var chargingInhibited: Bool { inhibit.map { isOn($0) } ?? false }
    var adapterDisabled: Bool { adapter.map { isOn($0) } ?? false }

    private func isOn(_ sw: SMCSwitch) -> Bool {
        guard let key = sw.keys.first, let value = smc.read(key) else { return false }
        return value.bytes == sw.onBytes
    }

    /// Writes the switch only when it differs, so the SMC isn't hammered every tick.
    @discardableResult
    private func set(_ sw: SMCSwitch?, _ on: Bool) -> String? {
        guard let sw else { return nil }
        let bytes = on ? sw.onBytes : sw.offBytes
        for key in sw.keys where smc.read(key)?.bytes != bytes {
            do { try smc.write(key, bytes) } catch { return "\(error)" }
        }
        return nil
    }

    func setChargingInhibited(_ on: Bool) -> String? { set(inhibit, on) }

    var nativeLimit: Int? { native?.current() }

    /// Sets macOS's own charge limit when it differs (the user may also change it in System Settings).
    func setNativeLimit(_ limit: Int) -> String? {
        guard let native, native.current() != limit else { return nil }
        return native.set(limit)
    }
    func setAdapterDisabled(_ on: Bool) -> String? { set(adapter, on) }

    func setLED(_ color: LEDColor) {
        guard capabilities.magSafeLED else { return }
        // Hand the LED back to macOS once, then leave it alone.
        if color == .system, lastLED == .system || lastLED == nil { lastLED = .system; return }
        let value: UInt8 = switch color {
        case .system: 0x00
        case .off: 0x01
        case .green: 0x03
        case .amber: 0x04
        }
        if color == .system || smc.read("ACLC")?.bytes != [value] { try? smc.write("ACLC", [value]) }
        lastLED = color
    }

    /// Hands charging back to macOS.
    func restore() {
        set(inhibit, false)
        set(adapter, false)
        if lastLED != nil && lastLED != .system { try? smc.write("ACLC", [0x00]) }
        lastLED = .system
    }

    // MARK: Power modes

    func setLowPowerMode(_ on: Bool) -> String? {
        Self.run("/usr/bin/pmset", ["-a", "lowpowermode", on ? "1" : "0"]) == nil ? "pmset a échoué" : nil
    }

    func setHighPowerMode(_ on: Bool) -> String? {
        guard capabilities.highPowerMode else { return "Le mode haute puissance n'existe pas sur ce Mac" }
        return Self.run("/usr/bin/pmset", ["-a", "powermode", on ? "2" : "0"]) == nil ? "pmset a échoué" : nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: output, as: UTF8.self) : nil
    }
}
