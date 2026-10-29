import AppKit
import ChargePilotCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            if model.helperStatus == .running || model.helperStatus == .outdated {
                Divider()
                limitSection
                Divider()
                tasksSection
                Divider()
                togglesSection
            }
            Divider()
            statsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.displayPercent) %")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                StatusPill(status: model.status)
            }
            ChargeBar(percent: model.displayPercent, limit: model.config.limit, status: model.status)
            HStack(spacing: 6) {
                Text(subtitle)
                Spacer()
                if let t = model.battery.temperature {
                    Label(String(format: "%.1f °C", t), systemImage: "thermometer.medium")
                        .foregroundStyle(model.helper.heatBlocked ? .orange : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let b = model.battery
        if model.helper.mode.isTask { return model.helper.mode.label }
        if let minutes = b.timeToFull, b.isCharging { return "Pleine dans \(Format.duration(minutes))" }
        if let minutes = b.timeToEmpty { return "\(Format.duration(minutes)) restantes" }
        if b.externalConnected { return b.adapterName ?? "Sur secteur" }
        return "Sur batterie"
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        switch model.helperStatus {
        case .notInstalled:
            Banner(icon: "lock.shield", tint: .accentColor,
                   text: "ChargePilot a besoin de son assistant pour contrôler la charge. Il s'installe une fois, avec votre mot de passe.") {
                Button("Installer l'assistant") { model.installHelper() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
        case .unreachable(let message):
            if let problem = AppModel.signatureProblem {
                Banner(icon: "exclamationmark.triangle", tint: .orange, text: problem)
            } else {
                Banner(icon: "exclamationmark.triangle", tint: .orange, text: "L'assistant ne répond pas. \(message)") {
                    Button("Réinstaller l'assistant") { model.installHelper() }.disabled(model.busy)
                }
            }
        case .outdated:
            Banner(icon: "arrow.triangle.2.circlepath", tint: .accentColor, text: "Une nouvelle version de l'assistant est incluse.") {
                Button("Mettre à jour") { model.installHelper() }.disabled(model.busy)
            }
        case .checking, .running:
            EmptyView()
        }
        if let native = model.nativeLimit, native < model.config.limit, model.config.enabled, model.helper.capabilities.nativeSteps.isEmpty {
            Banner(icon: "info.circle", tint: .secondary,
                   text: "macOS limite déjà la charge à \(native) % (Réglages Système › Batterie). Réglez-le sur 100 % pour laisser ChargePilot décider.")
        }
        if model.helperStatus == .running, model.config.enabled, model.config.limit < 100, model.alternatesPower {
            let steps = model.helper.capabilities.nativeSteps.filter { $0 < 100 }
            Banner(icon: "info.circle", tint: .secondary,
                   text: steps.isEmpty
                       ? "Ce Mac ne permet pas de suspendre la charge : ChargePilot tient la limite en alternant secteur et batterie."
                       : "À \(model.config.limit) %\(model.config.sailing ? " avec la navigation" : ""), ChargePilot alterne secteur et batterie. Sans navigation, macOS tient lui-même \(steps.map(String.init).joined(separator: ", ")) % sans solliciter la batterie.")
        }
        if let error = model.lastError ?? model.helper.lastError {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Limit

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Limite de charge").font(.headline)
                Spacer()
                Text(model.config.limit >= 100 ? "Aucune" : "\(model.config.limit) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { Double(model.config.limit) }, set: { model.setLimit(Int($0.rounded())) }),
                in: Double(ChargeConfig.limitRange.lowerBound)...Double(ChargeConfig.limitRange.upperBound),
                step: 1
            )
            .disabled(!model.config.enabled)
            HStack(spacing: 6) {
                ForEach([60, 70, 80, 85, 90, 100], id: \.self) { value in
                    Button("\(value)") { model.setLimit(value) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.config.limit == value ? .accentColor : nil)
                }
            }
            .disabled(!model.config.enabled)
        }
    }

    // MARK: Tasks

    @ViewBuilder
    private var tasksSection: some View {
        let caps = model.helper.capabilities
        if model.helper.mode.isTask {
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading) {
                    Text(model.helper.mode.label).font(.callout.weight(.medium))
                    if case .calibration(let phase, _) = model.helper.mode {
                        Text("Étape \(phase.step) sur 4 — gardez le Mac branché").font(.caption).foregroundStyle(.secondary)
                    }
                    if case .cycle(let low, let high, _, let count) = model.helper.mode {
                        Text("\(low) – \(high) % · \(count == 0 ? "premier cycle" : "\(count + 1)e cycle") · s'arrête au débranchement")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Annuler") { model.perform(.cancel) }
            }
        } else {
            HStack(spacing: 6) {
                TaskButton(title: "Recharger", icon: "bolt.fill", help: "Charger une fois jusqu'à 100 % ; la limite revient au débranchement") {
                    model.perform(.topUp)
                }
                TaskButton(title: "Décharger", icon: "arrow.down.circle", help: "Utiliser la batterie sur secteur jusqu'à la limite") {
                    model.perform(.discharge, value: model.config.limit)
                }
                .disabled(!caps.canDisableAdapter || model.displayPercent <= model.config.limit || !model.battery.externalConnected)
                TaskButton(title: "Cycles", icon: "repeat", help: "Sur un dock : tourner sur batterie jusqu'à \(model.config.cycleLow) %, recharger jusqu'à \(model.config.cycleHigh) %, et recommencer jusqu'au débranchement") {
                    model.perform(.cycle)
                }
                .disabled(!caps.canDisableAdapter || !model.battery.externalConnected)
                TaskButton(title: "Calibrer", icon: "arrow.triangle.2.circlepath", help: "Décharger à \(model.config.calibrationLowPercent) %, charger à 100 %, patienter puis revenir à la limite") {
                    model.perform(.calibrate)
                }
                .disabled(!caps.canDisableAdapter)
            }
            .disabled(!model.config.enabled)
        }
    }

    // MARK: Toggles

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.config.sailing) {
                Label("Navigation (\(model.config.sailingGap) %)", systemImage: "sailboat")
            }
            Toggle(isOn: $model.config.heatProtection) {
                Label("Protection thermique (\(Int(model.config.heatThreshold)) °C)", systemImage: "thermometer.sun")
            }
            Toggle(isOn: Binding(get: { model.lowPowerMode }, set: { model.setLowPowerMode($0) })) {
                Label("Économie d'énergie", systemImage: "leaf")
            }
            if model.helper.capabilities.highPowerMode {
                Toggle(isOn: Binding(get: { model.highPowerMode }, set: { model.setHighPowerMode($0) })) {
                    Label("Haute puissance", systemImage: "bolt.horizontal")
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Stats

    private var statsSection: some View {
        let b = model.battery
        return VStack(alignment: .leading, spacing: 6) {
            PowerFlowView(battery: b, adapterDisabled: model.helper.adapterDisabled)
            HStack {
                if let health = b.health {
                    Stat(title: "Santé", value: String(format: "%.0f %%", health))
                }
                Stat(title: "Cycles", value: "\(b.cycleCount)")
                Stat(title: "Tension", value: String(format: "%.2f V", b.voltage))
                Stat(title: "Matériel", value: String(format: "%.1f %%", b.hardwarePercent))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.helperStatus == .running {
                Button(model.config.enabled ? "Mettre en pause" : "Reprendre") {
                    model.perform(model.config.enabled ? .pause : .resume)
                }
                .help(model.config.enabled ? "Laisser macOS charger normalement" : "Reprendre la limitation de charge")
            }
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate()
            } label: { Image(systemName: "gearshape") }
                .help("Réglages")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .help("Quitter ChargePilot")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: Components

struct StatusPill: View {
    let status: ChargeStatus

    var body: some View {
        Text(status.shortLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

extension ChargeStatus {
    var tint: Color {
        switch self {
        case .charging: return .orange
        case .limitReached, .full: return .green
        case .sailing: return .teal
        case .discharging: return .blue
        case .heatProtection: return .red
        case .onBattery, .disabled: return .secondary
        case .notInstalled: return .orange
        }
    }

    var shortLabel: String {
        switch self {
        case .disabled: return "En pause"
        case .notInstalled: return "Inactif"
        default: return label
        }
    }
}

struct ChargeBar: View {
    let percent: Int
    let limit: Int
    let status: ChargeStatus

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(status.tint == .secondary ? Color.accentColor : status.tint)
                    .frame(width: max(6, geo.size.width * CGFloat(percent) / 100))
                if limit < 100 {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * CGFloat(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 8)
        .padding(.vertical, 3)
        .accessibilityLabel("Charge \(percent) %, limite \(limit) %")
    }
}

struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    init(icon: String, tint: Color, text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TaskButton: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wall → Mac → battery, with the watts flowing along each edge.
struct PowerFlowView: View {
    let battery: BatterySnapshot
    let adapterDisabled: Bool

    var body: some View {
        let wall = battery.systemPowerIn ?? 0
        let load = battery.systemLoad ?? max(0, wall - battery.batteryPower)
        let batteryPower = battery.batteryPower
        HStack(spacing: 6) {
            node("powerplug", adapterDisabled ? "Coupé" : (battery.externalConnected ? Format.watts(wall) : "—"),
                 active: battery.externalConnected && !adapterDisabled)
            arrow(active: wall > 0.5)
            node("laptopcomputer", Format.watts(load), active: true)
            Image(systemName: batteryPower > 0.3 ? "arrow.right" : (batteryPower < -0.3 ? "arrow.left" : "minus"))
                .foregroundStyle(abs(batteryPower) > 0.3 ? Color.accentColor : Color.secondary)
                .font(.caption)
            node(batteryPower > 0.3 ? "battery.100percent.bolt" : "battery.75percent",
                 String(format: "%+.1f W", batteryPower), active: abs(batteryPower) > 0.3)
        }
    }

    private func node(_ icon: String, _ value: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.title3).foregroundStyle(active ? .primary : .tertiary)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func arrow(active: Bool) -> some View {
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
    }
}

enum Format {
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    static func watts(_ value: Double) -> String {
        String(format: value >= 10 ? "%.0f W" : "%.1f W", value)
    }
}
