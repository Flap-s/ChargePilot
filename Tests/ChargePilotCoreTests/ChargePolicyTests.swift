import XCTest
@testable import ChargePilotCore

final class ChargePolicyTests: XCTestCase {
    private func battery(_ percent: Int, plugged: Bool = true, charging: Bool = true, temperature: Double? = 30) -> BatterySnapshot {
        var b = BatterySnapshot()
        b.present = true
        b.percent = percent
        b.hardwarePercent = Double(percent)
        b.externalConnected = plugged
        b.isCharging = charging && plugged
        b.temperature = temperature
        return b
    }

    private var inhibitCaps: HardwareCapabilities {
        var c = HardwareCapabilities()
        c.chargeInhibitKey = "CHTE"
        c.adapterKey = "CHIE"
        return c
    }

    private var adapterOnlyCaps: HardwareCapabilities {
        var c = HardwareCapabilities()
        c.adapterKey = "CHIE"
        return c
    }

    func testChargesBelowLimitAndStopsAtLimit() {
        var policy = ChargePolicy()
        let config = ChargeConfig()
        var (d, events) = policy.evaluate(battery(70), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertFalse(d.inhibitCharging)
        XCTAssertEqual(d.status, .charging)
        XCTAssertTrue(events.isEmpty)

        (d, events) = policy.evaluate(battery(80), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertTrue(d.inhibitCharging)
        XCTAssertEqual(d.status, .limitReached)
        XCTAssertEqual(events.map(\.kind), [.limitReached])

        // The event fires once per charge.
        (_, events) = policy.evaluate(battery(80), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertTrue(events.isEmpty)

        (d, _) = policy.evaluate(battery(79), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertFalse(d.inhibitCharging)
    }

    func testSailingWaitsForTheGap() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.sailing = true
        config.sailingGap = 5
        _ = policy.evaluate(battery(80), config: config, capabilities: inhibitCaps, active: true)
        var (d, _) = policy.evaluate(battery(76), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertTrue(d.inhibitCharging)
        XCTAssertEqual(d.status, .sailing)
        (d, _) = policy.evaluate(battery(74), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertFalse(d.inhibitCharging)
        XCTAssertEqual(d.status, .charging)
    }

    func testInactiveHandsBackToMacOS() {
        var policy = ChargePolicy()
        let (d, _) = policy.evaluate(battery(95), config: ChargeConfig(), capabilities: inhibitCaps, active: false)
        XCTAssertFalse(d.inhibitCharging)
        XCTAssertFalse(d.disableAdapter)
        XCTAssertEqual(d.status, .disabled)
    }

    func testTopUpChargesToFullAndEndsOnUnplug() {
        var policy = ChargePolicy()
        policy.start(.topUp)
        var (d, _) = policy.evaluate(battery(90), config: ChargeConfig(), capabilities: inhibitCaps, active: true)
        XCTAssertFalse(d.inhibitCharging)
        var full = battery(100, charging: false)
        full.fullyCharged = true
        let events: [HelperEvent]
        (d, events) = policy.evaluate(full, config: ChargeConfig(), capabilities: inhibitCaps, active: true)
        XCTAssertEqual(d.status, .full)
        XCTAssertEqual(events.map(\.kind), [.topUpDone])
        _ = policy.evaluate(battery(99, plugged: false), config: ChargeConfig(), capabilities: inhibitCaps, active: true)
        XCTAssertEqual(policy.mode, .normal)
    }

    func testDischargeCutsAdapterUntilTarget() {
        var policy = ChargePolicy()
        policy.start(.discharge(target: 60))
        var (d, _) = policy.evaluate(battery(70), config: ChargeConfig(), capabilities: inhibitCaps, active: true)
        XCTAssertTrue(d.disableAdapter)
        XCTAssertEqual(d.status, .discharging)
        // macOS may report the cut adapter as unplugged.
        (d, _) = policy.evaluate(battery(65, plugged: false), config: ChargeConfig(), capabilities: inhibitCaps, active: true, adapterDisabled: true)
        XCTAssertTrue(d.disableAdapter)
        let events: [HelperEvent]
        (d, events) = policy.evaluate(battery(60), config: ChargeConfig(), capabilities: inhibitCaps, active: true, adapterDisabled: true)
        XCTAssertFalse(d.disableAdapter)
        XCTAssertEqual(policy.mode, .normal)
        XCTAssertEqual(events.first?.kind, .dischargeDone)
    }

    func testHeatProtectionPausesCharging() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.heatProtection = true
        config.heatThreshold = 35
        var (d, events) = policy.evaluate(battery(50, temperature: 36), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertTrue(d.inhibitCharging)
        XCTAssertEqual(d.status, .heatProtection)
        XCTAssertEqual(events.map(\.kind), [.heatPaused])
        (d, _) = policy.evaluate(battery(50, temperature: 34), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertTrue(d.inhibitCharging, "stays paused inside the hysteresis")
        (d, events) = policy.evaluate(battery(50, temperature: 32.5), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertFalse(d.inhibitCharging)
        XCTAssertEqual(events.map(\.kind), [.heatResumed])
    }

    func testCalibrationRunsAllPhases() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.calibrationHoldMinutes = 60
        let start = Date(timeIntervalSince1970: 1_000_000)
        policy.startCalibration(now: start)
        var (d, _) = policy.evaluate(battery(50), config: config, capabilities: inhibitCaps, active: true, now: start)
        XCTAssertTrue(d.disableAdapter)
        (d, _) = policy.evaluate(battery(15), config: config, capabilities: inhibitCaps, active: true, adapterDisabled: true, now: start)
        XCTAssertEqual(policy.mode, .calibration(phase: .chargeFull, since: start))
        XCTAssertFalse(d.disableAdapter)
        XCTAssertFalse(d.inhibitCharging)
        var full = battery(100, charging: false)
        full.fullyCharged = true
        _ = policy.evaluate(full, config: config, capabilities: inhibitCaps, active: true, now: start)
        XCTAssertEqual(policy.mode, .calibration(phase: .holdFull, since: start))
        let later = start.addingTimeInterval(3601)
        (d, _) = policy.evaluate(full, config: config, capabilities: inhibitCaps, active: true, now: later)
        XCTAssertEqual(policy.mode, .calibration(phase: .dischargeToLimit, since: later))
        XCTAssertTrue(d.disableAdapter)
        let events: [HelperEvent]
        (d, events) = policy.evaluate(battery(80), config: config, capabilities: inhibitCaps, active: true, adapterDisabled: true, now: later)
        XCTAssertEqual(policy.mode, .normal)
        XCTAssertEqual(policy.lastCalibration, later)
        XCTAssertTrue(events.contains { $0.kind == .calibrationDone })
        XCTAssertTrue(d.inhibitCharging)
    }

    func testAdapterOnlyMacsCycleThroughABand() {
        var policy = ChargePolicy()
        let config = ChargeConfig()
        var (d, _) = policy.evaluate(battery(80), config: config, capabilities: adapterOnlyCaps, active: true)
        XCTAssertTrue(d.disableAdapter)
        (d, _) = policy.evaluate(battery(79, plugged: false), config: config, capabilities: adapterOnlyCaps, active: true, adapterDisabled: true)
        XCTAssertTrue(d.disableAdapter)
        (d, _) = policy.evaluate(battery(77, plugged: false), config: config, capabilities: adapterOnlyCaps, active: true, adapterDisabled: true)
        XCTAssertFalse(d.disableAdapter)
    }

    func testAutomaticLED() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.magSafeLED = .automatic
        var (d, _) = policy.evaluate(battery(50), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertEqual(d.led, .amber)
        (d, _) = policy.evaluate(battery(80), config: config, capabilities: inhibitCaps, active: true)
        XCTAssertEqual(d.led, .green)
    }
}

final class ScheduleTests: XCTestCase {
    func testDueWithinWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        var item = ScheduleItem()
        item.hour = 8
        item.minute = 30
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 8, minute: 30, second: 5))!
        XCTAssertEqual(ScheduleRunner.due([item], from: at.addingTimeInterval(-10), to: at, calendar: calendar).count, 1)
        XCTAssertTrue(ScheduleRunner.due([item], from: at, to: at.addingTimeInterval(10), calendar: calendar).isEmpty)
        // Wrong weekday (28 October 2026 is a Wednesday = 4).
        item.weekdays = [2]
        XCTAssertTrue(ScheduleRunner.due([item], from: at.addingTimeInterval(-10), to: at, calendar: calendar).isEmpty)
        item.weekdays = [4]
        XCTAssertEqual(ScheduleRunner.due([item], from: at.addingTimeInterval(-10), to: at, calendar: calendar).count, 1)
    }

    func testMissedLongAgoIsSkipped() {
        var item = ScheduleItem()
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        item.hour = 9
        XCTAssertTrue(ScheduleRunner.due([item], from: now.addingTimeInterval(-6 * 3600), to: now, calendar: calendar).isEmpty)
    }
}

final class SMCValueTests: XCTestCase {
    func testDecoding() {
        XCTAssertEqual(FourCC("CHIE").description, "CHIE")
        XCTAssertEqual([UInt8](hex: "0x01ff"), [1, 255])
        let float = SMCValue(key: FourCC("TB0T"), type: FourCC("flt "), bytes: [0x98, 0x99, 0xdd, 0x41], attributes: 0)
        XCTAssertEqual(float.number!, 27.7, accuracy: 0.01)
        let voltage = SMCValue(key: FourCC("B0AV"), type: FourCC("ui16"), bytes: [0xe2, 0x2e], attributes: 0)
        XCTAssertEqual(voltage.number, 12002)
        let current = SMCValue(key: FourCC("B0AC"), type: FourCC("si16"), bytes: [0x3f, 0xfe], attributes: 0)
        XCTAssertEqual(current.number, -449)
    }
}

final class NativeLimitPolicyTests: XCTestCase {
    private var caps: HardwareCapabilities {
        var c = HardwareCapabilities()
        c.adapterKey = "CHIE"
        c.nativeLimitSteps = [80, 85, 90, 95, 100]
        return c
    }

    private func battery(_ percent: Int, plugged: Bool = true) -> BatterySnapshot {
        var b = BatterySnapshot()
        b.present = true
        b.percent = percent
        b.externalConnected = plugged
        b.isCharging = plugged
        return b
    }

    func testStepLimitIsHeldNatively() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.limit = 85
        let (d, events) = policy.evaluate(battery(85), config: config, capabilities: caps, active: true)
        XCTAssertEqual(d.nativeLimit, 85)
        XCTAssertFalse(d.disableAdapter, "macOS pauses charging; no need to run on battery")
        XCTAssertEqual(d.status, .limitReached)
        XCTAssertEqual(events.map(\.kind), [.limitReached])
    }

    func testOtherLimitsCutTheAdapterUnderANativeCeiling() {
        var policy = ChargePolicy()
        var config = ChargeConfig()
        config.limit = 60
        let (d, _) = policy.evaluate(battery(60), config: config, capabilities: caps, active: true)
        XCTAssertEqual(d.nativeLimit, 80)
        XCTAssertTrue(d.disableAdapter)
        config.limit = 87
        let (d2, _) = policy.evaluate(battery(87), config: config, capabilities: caps, active: true)
        XCTAssertEqual(d2.nativeLimit, 90)
        XCTAssertTrue(d2.disableAdapter)
    }

    func testTopUpTurnsTheNativeLimitOff() {
        var policy = ChargePolicy()
        policy.start(.topUp)
        let (d, _) = policy.evaluate(battery(85), config: ChargeConfig(), capabilities: caps, active: true)
        XCTAssertEqual(d.nativeLimit, 100)
    }

    func testInactiveLeavesItAlone() {
        var policy = ChargePolicy()
        let (d, _) = policy.evaluate(battery(85), config: ChargeConfig(), capabilities: caps, active: false)
        XCTAssertNil(d.nativeLimit)
    }
}

final class LoweredLimitTests: XCTestCase {
    func testLoweringTheLimitDischargesWithoutAnnouncingIt() {
        var caps = HardwareCapabilities()
        caps.adapterKey = "CHIE"
        caps.nativeLimitSteps = [80, 85, 90, 95, 100]
        var b = BatterySnapshot()
        b.present = true
        b.percent = 80
        b.externalConnected = true
        var config = ChargeConfig()
        config.limit = 60
        var policy = ChargePolicy()
        var (d, events) = policy.evaluate(b, config: config, capabilities: caps, active: true)
        XCTAssertEqual(d.status, .discharging)
        XCTAssertTrue(d.disableAdapter)
        XCTAssertTrue(events.isEmpty)
        b.percent = 60
        (d, events) = policy.evaluate(b, config: config, capabilities: caps, active: true, adapterDisabled: true)
        XCTAssertEqual(d.status, .limitReached)
        XCTAssertEqual(events.map(\.kind), [.limitReached])
    }
}

final class CycleTests: XCTestCase {
    private var caps: HardwareCapabilities {
        var c = HardwareCapabilities()
        c.adapterKey = "CHIE"
        c.nativeLimitSteps = [80, 85, 90, 95, 100]
        return c
    }

    private func battery(_ percent: Int, plugged: Bool = true, charging: Bool = true) -> BatterySnapshot {
        var b = BatterySnapshot()
        b.present = true
        b.percent = percent
        b.hardwarePercent = Double(percent)
        b.externalConnected = plugged
        b.isCharging = charging && plugged
        return b
    }

    func testCyclesDrainThenChargeThenDrainAgain() {
        var config = ChargeConfig()
        config.cycleLow = 30
        config.cycleHigh = 85
        var policy = ChargePolicy()
        policy.startCycles(config: config, percent: 80)
        XCTAssertEqual(policy.mode, .cycle(low: 30, high: 85, draining: true, count: 0))

        var (d, events) = policy.evaluate(battery(50), config: config, capabilities: caps, active: true)
        XCTAssertTrue(d.disableAdapter)
        XCTAssertEqual(d.status, .discharging)
        XCTAssertEqual(d.nativeLimit, 85, "macOS caps the charge at the top of the cycle")

        (d, events) = policy.evaluate(battery(30, plugged: false), config: config, capabilities: caps, active: true, adapterDisabled: true)
        XCTAssertFalse(d.disableAdapter)
        XCTAssertEqual(d.status, .charging)
        XCTAssertEqual(events.map(\.kind), [.cycleCharge])

        (d, _) = policy.evaluate(battery(60), config: config, capabilities: caps, active: true)
        XCTAssertFalse(d.disableAdapter)

        (d, events) = policy.evaluate(battery(85), config: config, capabilities: caps, active: true)
        XCTAssertTrue(d.disableAdapter)
        XCTAssertEqual(events.map(\.kind), [.cycleDrain])
        XCTAssertEqual(policy.mode, .cycle(low: 30, high: 85, draining: true, count: 1))
    }

    func testUnpluggingStopsCyclesOnlyAfterTheGrace() {
        var config = ChargeConfig()
        config.cycleLow = 30
        var policy = ChargePolicy()
        policy.startCycles(config: config, percent: 20)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        // Right after the adapter comes back, macOS may still report it missing.
        var (d, events) = policy.evaluate(battery(31, plugged: false), config: config, capabilities: caps, active: true, now: t0)
        XCTAssertTrue(events.isEmpty)
        if case .cycle = policy.mode {} else { XCTFail("cycles should survive a brief glitch") }
        (_, events) = policy.evaluate(battery(31), config: config, capabilities: caps, active: true, now: t0.addingTimeInterval(10))
        XCTAssertTrue(events.isEmpty)
        // A real unplug.
        _ = policy.evaluate(battery(31, plugged: false), config: config, capabilities: caps, active: true, now: t0.addingTimeInterval(20))
        (d, events) = policy.evaluate(battery(30, plugged: false), config: config, capabilities: caps, active: true, now: t0.addingTimeInterval(55))
        XCTAssertEqual(policy.mode, .normal)
        XCTAssertEqual(events.map(\.kind), [.cycleStopped])
        XCTAssertFalse(d.disableAdapter)
    }
}

final class UpdateTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("v1.0.1")!)
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10.0")!)
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertEqual(AppVersion("2.0.0-beta"), AppVersion("2.0.0"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testReleaseSelection() throws {
        let json = """
        {"tag_name":"v1.2.0","name":"ChargePilot 1.2.0","body":"Notes","html_url":"https://github.com/o/ChargePilot/releases/tag/v1.2.0",
         "draft":false,"prerelease":false,
         "assets":[{"name":"ChargePilot.zip","browser_download_url":"https://github.com/o/ChargePilot/releases/download/v1.2.0/ChargePilot.zip","size":10}]}
        """
        let release = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertEqual(release.appArchive?.name, "ChargePilot.zip")
        XCTAssertTrue(release.isUpdate(from: AppVersion("1.1.9")!))
        XCTAssertFalse(release.isUpdate(from: AppVersion("1.2.0")!))
    }

    func testLatestRedirectFallback() {
        let page = URL(string: "https://github.com/o/ChargePilot/releases/tag/v1.3.0")!
        let release = GitHubRelease.fromLatestPage(page, repository: "o/ChargePilot")
        XCTAssertEqual(release?.version, AppVersion("1.3.0"))
        XCTAssertEqual(release?.appArchive?.browserDownloadUrl.absoluteString,
                       "https://github.com/o/ChargePilot/releases/download/v1.3.0/ChargePilot.zip")
        XCTAssertNil(GitHubRelease.fromLatestPage(URL(string: "https://github.com/o/ChargePilot/releases")!, repository: "o/ChargePilot"))
    }
}
