import Foundation
import ChargePilotCore

struct HistorySample: Codable, Identifiable {
    var date: Date
    var percent: Int
    var temperature: Double?
    var batteryPower: Double
    var systemLoad: Double?
    var plugged: Bool
    var charging: Bool

    var id: Date { date }
}

struct HealthSample: Codable, Identifiable {
    var date: Date
    var health: Double
    var cycles: Int
    var fullCapacity: Int

    var id: Date { date }
}

/// Keeps a minute-by-minute battery log for the charts, and one health reading per day.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [HistorySample] = []
    @Published private(set) var health: [HealthSample] = []

    private static let retention: TimeInterval = 14 * 24 * 3600
    private static let interval: TimeInterval = 60
    private var unsaved = 0

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChargePilot", isDirectory: true)
    }()
    private var samplesURL: URL { directory.appendingPathComponent("history.json") }
    private var healthURL: URL { directory.appendingPathComponent("health.json") }

    init() {
        // Carry the history over from Mesure, the app's former name.
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("Mesure", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        samples = (try? Data(contentsOf: samplesURL)).flatMap { try? JSON.decoder.decode([HistorySample].self, from: $0) } ?? []
        health = (try? Data(contentsOf: healthURL)).flatMap { try? JSON.decoder.decode([HealthSample].self, from: $0) } ?? []
    }

    func record(_ battery: BatterySnapshot) {
        guard battery.present else { return }
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.date) < Self.interval { return }
        samples.append(HistorySample(
            date: now, percent: battery.percent, temperature: battery.temperature, batteryPower: battery.batteryPower,
            systemLoad: battery.systemLoad, plugged: battery.externalConnected, charging: battery.isCharging
        ))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.retention }
        unsaved += 1
        if unsaved >= 10 { save() }

        if let value = battery.health, !Calendar.current.isDateInToday(health.last?.date ?? .distantPast) {
            health.append(HealthSample(date: now, health: value, cycles: battery.cycleCount, fullCapacity: battery.fullChargeCapacity))
            if let data = try? JSON.encoder.encode(health) { try? data.write(to: healthURL, options: .atomic) }
        }
    }

    func save() {
        unsaved = 0
        if let data = try? JSON.encoder.encode(samples) { try? data.write(to: samplesURL, options: .atomic) }
    }

    func samples(within interval: TimeInterval) -> [HistorySample] {
        let start = Date().addingTimeInterval(-interval)
        return samples.filter { $0.date >= start }
    }

    func clear() {
        samples.removeAll()
        save()
    }
}
