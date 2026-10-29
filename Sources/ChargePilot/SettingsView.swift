import Charts
import ChargePilotCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, charge, tasks, led, schedule, battery, helper, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Général"
        case .charge: return "Charge"
        case .tasks: return "Cycles et calibration"
        case .led: return "LED MagSafe"
        case .schedule: return "Planification"
        case .battery: return "Batterie"
        case .helper: return "Assistant"
        case .updates: return "Mises à jour"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .charge: return "bolt.batteryblock"
        case .tasks: return "repeat"
        case .led: return "light.beacon.max"
        case .schedule: return "calendar.badge.clock"
        case .battery: return "chart.xyaxis.line"
        case .helper: return "wrench.and.screwdriver"
        case .updates: return "arrow.down.circle"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .charge: ChargeSettings()
        case .tasks: TasksSettings()
        case .led: LEDSettings()
        case .schedule: ScheduleSettings()
        case .battery: BatteryInfoView()
        case .helper: HelperSettings()
        case .updates: UpdateSettings()
        }
    }
}

/// Settings with every section one click away in a sidebar, like System Settings.
struct SettingsView: View {
    @AppStorage("settingsPane") private var stored = SettingsPane.general.rawValue

    private var selection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: stored) ?? .general }, set: { stored = ($0 ?? .general).rawValue })
    }

    var body: some View {
        let pane = SettingsPane(rawValue: stored) ?? .general
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 235, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane.content
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Ouvrir ChargePilot à la connexion", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Continuer à limiter quand ChargePilot est fermé", isOn: $model.config.limitWhenAppClosed)
                Text("L'assistant tourne en arrière-plan : la limite tient même app fermée. Désactivé, macOS reprend la main dès que vous quittez ChargePilot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Barre des menus") {
                Picker("Affichage", selection: Binding(get: { model.menuBarStyle }, set: { model.menuBarStyle = $0 })) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Utiliser le pourcentage matériel", isOn: $model.config.useHardwarePercent)
                Text("macOS arrondit et lisse le pourcentage affiché. Le pourcentage matériel (\(String(format: "%.1f", model.battery.hardwarePercent)) %) est la charge réelle mesurée par la batterie ; ChargePilot l'utilise alors aussi pour la limite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Prévenir quand la limite est atteinte, une tâche se termine ou la batterie chauffe",
                       isOn: Binding(get: { model.notificationsEnabled }, set: { model.notificationsEnabled = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Charge

struct ChargeSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Limite") {
                LabeledContent("Limite de charge") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.config.limit) }, set: { model.setLimit(Int($0.rounded())) }), in: 20...100, step: 1)
                        Text("\(model.config.limit) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Décharger automatiquement au-dessus de la limite", isOn: $model.config.automaticDischarge)
                    .disabled(!model.helper.capabilities.canDisableAdapter)
                Text("Branché au-dessus de la limite (après une recharge à 100 %, par exemple), le Mac fonctionne sur batterie jusqu'à redescendre à la limite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Navigation") {
                Toggle("Laisser la charge dériver avant de recharger", isOn: $model.config.sailing)
                Stepper("Écart : \(model.config.sailingGap) %", value: $model.config.sailingGap, in: 1...30)
                    .disabled(!model.config.sailing)
                Text("À la limite, la charge reste suspendue jusqu'à ce que la batterie descende de \(model.config.sailingGap) % (\(max(0, model.config.limit - model.config.sailingGap)) %). Moins de micro-recharges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Protection thermique") {
                Toggle("Suspendre la charge quand la batterie chauffe", isOn: $model.config.heatProtection)
                Stepper("Seuil : \(Int(model.config.heatThreshold)) °C", value: $model.config.heatThreshold, in: 25...50, step: 1)
                    .disabled(!model.config.heatProtection)
                if let t = model.battery.temperature {
                    Text(String(format: "Température actuelle : %.1f °C. La charge reprend %.0f °C en dessous du seuil.", t, ChargePolicy.heatHysteresis))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Veille") {
                Toggle("Arrêter la charge pendant la veille", isOn: $model.config.stopChargingWhenSleeping)
                Toggle("Empêcher la veille tant que la limite n'est pas atteinte", isOn: $model.config.preventSleepUntilLimit)
                Text("ChargePilot ne peut pas agir pendant que le Mac dort. Sans ces options, une charge commencée avant la veille peut dépasser la limite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Cycles and calibration

struct TasksSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Cycles (Mac sur un dock)") {
                Stepper("Décharger jusqu'à \(model.config.cycleLow) %", value: $model.config.cycleLow, in: 10...80, step: 5)
                Stepper("Recharger jusqu'à \(model.config.cycleHigh) %", value: $model.config.cycleHigh,
                        in: min(100, model.config.cycleLow + 10)...100, step: 5)
                Text("Pour un Mac qui reste branché : il tourne sur batterie jusqu'au seuil bas, se recharge jusqu'au seuil haut, et recommence. Les cycles s'arrêtent quand vous débranchez le Mac ; la limite de charge reprend alors. Lancez-les depuis le menu, un lien chargepilot://cycle ou une tâche planifiée.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calibration") {
                Stepper("Décharger jusqu'à \(model.config.calibrationLowPercent) %", value: $model.config.calibrationLowPercent, in: 5...50)
                Stepper("Maintenir à 100 % pendant \(model.config.calibrationHoldMinutes) min", value: $model.config.calibrationHoldMinutes, in: 0...240, step: 15)
                LabeledContent("Dernière calibration") {
                    Text(model.helper.lastCalibration.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Jamais")
                }
                Text("La calibration recale la jauge : décharge, charge complète, pause, puis retour à la limite. Gardez le Mac branché ; comptez quelques heures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: MagSafe

struct LEDSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if !model.helper.capabilities.magSafeLED {
                Text("Ce Mac n'a pas de LED MagSafe pilotable.").foregroundStyle(.secondary)
            }
            Section("LED MagSafe") {
                Picker("Couleur", selection: $model.config.magSafeLED) {
                    ForEach(MagSafeLEDMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Éteindre la LED pendant la veille", isOn: $model.config.ledOffWhileSleeping)
                Text("En automatique, la LED est orange pendant la charge, verte une fois la limite atteinte et éteinte pendant une décharge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.helper.capabilities.magSafeLED)
        }
        .formStyle(.grouped)
    }
}

// MARK: Schedules

struct ScheduleSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.config.schedules.isEmpty {
                    Text("Aucune tâche planifiée. Par exemple : recharger à 100 % le lundi à 7 h avant un déplacement, ou calibrer le premier dimanche.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.config.schedules) { $item in
                    ScheduleRow(item: $item) {
                        model.config.schedules.removeAll { $0.id == item.id }
                    }
                }
            } header: {
                HStack {
                    Text("Tâches planifiées")
                    Spacer()
                    Button {
                        model.config.schedules.append(ScheduleItem())
                    } label: { Label("Ajouter", systemImage: "plus") }
                }
            } footer: {
                Text("Les tâches s'exécutent dans l'assistant, même app fermée, si le Mac est éveillé à l'heure dite (rattrapage jusqu'à 10 min).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScheduleRow: View {
    @Binding var item: ScheduleItem
    let remove: () -> Void

    private static let weekdays: [(Int, String)] = [(2, "L"), (3, "M"), (4, "M"), (5, "J"), (6, "V"), (7, "S"), (1, "D")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $item.enabled).labelsHidden()
                Picker("", selection: $item.action) {
                    ForEach(ScheduledAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
                if item.action.takesValue {
                    Stepper("\(item.value) %", value: $item.value, in: 20...100, step: 5)
                }
                Spacer()
                DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                ForEach(Self.weekdays, id: \.0) { day, letter in
                    let on = item.weekdays.contains(day)
                    Button(letter) {
                        if on { item.weekdays.remove(day) } else { item.weekdays.insert(day) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(on ? .accentColor : nil)
                }
                Text(item.weekdays.isEmpty ? "Tous les jours" : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let next = ScheduleRunner.next(item, after: Date()), item.enabled {
                    Text("Prochaine : \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                item.hour = parts.hour ?? 8
                item.minute = parts.minute ?? 0
            }
        )
    }
}

// MARK: Battery

struct BatteryInfoView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore
    @State private var range: TimeInterval = 24 * 3600
    @State private var metric = Metric.percent

    enum Metric: String, CaseIterable {
        case percent = "Charge", temperature = "Température", power = "Puissance"
    }

    var body: some View {
        let b = model.battery
        Form {
            Section("Batterie") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        info("Charge", "\(b.percent) % (matériel \(String(format: "%.1f", b.hardwarePercent)) %)")
                        info("Santé", b.health.map { String(format: "%.1f %%", $0) } ?? "—")
                    }
                    GridRow {
                        info("Cycles", "\(b.cycleCount)")
                        info("Capacité", "\(b.remainingCapacity) / \(b.fullChargeCapacity) mAh")
                    }
                    GridRow {
                        info("Capacité nominale", "\(b.nominalCapacity) mAh (conception \(b.designCapacity))")
                        info("Température", b.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                    }
                    GridRow {
                        info("Tension", String(format: "%.3f V", b.voltage))
                        info("Courant", String(format: "%+.3f A", b.amperage))
                    }
                    GridRow {
                        info("Cellules", b.cellVoltages.map { String(format: "%.3f", $0) }.joined(separator: " · ") + (b.cellVoltages.isEmpty ? "—" : " V"))
                        info("N° de série", b.serial ?? "—")
                    }
                    if b.externalConnected {
                        GridRow {
                            info("Adaptateur", b.adapterName ?? "—")
                            info("Puissance", [b.adapterWatts.map { "\($0) W négociés" }, b.adapterVoltage.map { String(format: "%.0f V", $0) }]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
            }
            Section {
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                chart.frame(height: 170)
                Picker("Période", selection: $range) {
                    Text("6 h").tag(6.0 * 3600)
                    Text("24 h").tag(24.0 * 3600)
                    Text("7 j").tag(7.0 * 24 * 3600)
                    Text("14 j").tag(14.0 * 24 * 3600)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Historique")
            }
            if history.health.count > 1 {
                Section("Santé au fil du temps") {
                    Chart(history.health) {
                        LineMark(x: .value("Date", $0.date), y: .value("Santé", $0.health))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 120)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let samples = history.samples(within: range)
        if samples.count < 2 {
            Text("L'historique se remplit au fil des minutes.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch metric {
            case .percent:
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Heure", s.date), y: .value("Charge", s.percent))
                            .foregroundStyle(.green.opacity(0.25))
                        LineMark(x: .value("Heure", s.date), y: .value("Charge", s.percent))
                            .foregroundStyle(.green)
                    }
                    if model.config.limit < 100 {
                        RuleMark(y: .value("Limite", model.config.limit))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: 0...100)
            case .temperature:
                Chart(samples.filter { $0.temperature != nil }) {
                    LineMark(x: .value("Heure", $0.date), y: .value("°C", $0.temperature ?? 0)).foregroundStyle(.orange)
                }
                .chartYScale(domain: .automatic(includesZero: false))
            case .power:
                Chart(samples) {
                    LineMark(x: .value("Heure", $0.date), y: .value("W", $0.batteryPower), series: .value("Série", "Batterie"))
                        .foregroundStyle(by: .value("Série", "Batterie"))
                    if let load = $0.systemLoad {
                        LineMark(x: .value("Heure", $0.date), y: .value("W", load), series: .value("Série", "Mac"))
                            .foregroundStyle(by: .value("Série", "Mac"))
                    }
                }
            }
        }
    }
}

// MARK: Updates

struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @State private var repositoryDraft = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Version installée") { Text(updater.currentVersion) }
                LabeledContent("Dernière vérification") {
                    Text(updater.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Jamais")
                }
                status
                HStack {
                    Button("Rechercher une mise à jour") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.isBusy || updater.repository == nil)
                    if updater.isBusy { ProgressView().controlSize(.small) }
                }
                Toggle("Rechercher automatiquement (toutes les 6 heures)", isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
            }
            if let release = updater.availableRelease {
                Section("ChargePilot \(release.version?.description ?? release.tagName)") {
                    if let notes = release.body, !notes.isEmpty {
                        Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Télécharger et installer") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                        Link("Voir sur GitHub", destination: release.htmlUrl)
                    }
                    Text("ChargePilot se fermera, se remplacera puis se relancera. Si la nouvelle version contient un assistant modifié, votre mot de passe sera demandé une fois.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Source") {
                if let built = updater.builtInRepository {
                    LabeledContent("Dépôt GitHub") {
                        if let url = updater.repositoryURL { Link(built, destination: url) } else { Text(built) }
                    }
                } else {
                    TextField("Dépôt GitHub", text: $repositoryDraft, prompt: Text("propriétaire/ChargePilot"))
                        .onSubmit { updater.repository = repositoryDraft }
                    Button("Enregistrer le dépôt") { updater.repository = repositoryDraft }
                        .disabled(repositoryDraft.trimmingCharacters(in: .whitespaces) == (updater.repository ?? ""))
                    Text("Cette version a été construite avant la publication sur GitHub. Indiquez le dépôt (par exemple Flap-s/ChargePilot) ; les versions publiées le contiendront d'office.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Les mises à jour viennent des publications (Releases) du dépôt : l'archive ChargePilot.zip est téléchargée, son identité et sa signature vérifiées, puis elle remplace l'app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { repositoryDraft = updater.repository ?? "" }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle: EmptyView()
        case .checking: Label("Recherche…", systemImage: "magnifyingglass")
        case .upToDate: Label("ChargePilot est à jour.", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .available(let release):
            Label("Version \(release.version?.description ?? release.tagName) disponible", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: Label("Téléchargement…", systemImage: "arrow.down.circle")
        case .installing: Label("Installation…", systemImage: "shippingbox")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

// MARK: Helper

struct HelperSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = "CHIE"
    @State private var smcOutput = ""

    var body: some View {
        let caps = model.helper.capabilities
        Form {
            Section("Assistant") {
                LabeledContent("État") { Text(statusText) }
                if model.helperStatus == .running || model.helperStatus == .outdated {
                    LabeledContent("Version") { Text(model.helper.helperVersion) }
                    LabeledContent("Suspension de la charge") { Text(caps.chargeInhibitKey.map { "Oui (\($0))" } ?? "Non disponible") }
                    LabeledContent("Coupure de l'adaptateur") { Text(caps.adapterKey.map { "Oui (\($0))" } ?? "Non disponible") }
                    LabeledContent("LED MagSafe") { Text(caps.magSafeLED ? "Oui" : "Non") }
                    LabeledContent("Mode haute puissance") { Text(caps.highPowerMode ? "Oui" : "Non") }
                    LabeledContent("Limite native de macOS") {
                        Text(caps.nativeSteps.isEmpty ? "Non disponible" : "Pilotée par ChargePilot (\(caps.nativeSteps.filter { $0 < 100 }.map(String.init).joined(separator: ", ")) %)")
                    }
                }
                HStack {
                    Button(HelperInstaller.isInstalled ? "Réinstaller" : "Installer") { model.installHelper() }
                    if HelperInstaller.isInstalled {
                        Button("Désinstaller", role: .destructive) { model.uninstallHelper() }
                    }
                }
                Text("L'assistant est un petit service système (launchd) qui écrit dans le contrôleur de gestion du système (SMC). Il n'accepte que ChargePilot et son outil en ligne de commande.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ligne de commande et Raccourcis") {
                HStack {
                    Text(HelperInstaller.cliInstalled ? "Installée dans \(HelperInstaller.cliLink)" : "Commande « chargepilot » non installée")
                    Spacer()
                    Button(HelperInstaller.cliInstalled ? "Retirer" : "Installer") { model.toggleCLI() }
                }
                Text("Exemples : chargepilot status · chargepilot limit 80 · chargepilot topup · chargepilot cycles 30 85 · chargepilot discharge 50. Dans Raccourcis, utilisez « Exécuter un script shell » ou ouvrez un lien chargepilot://limit/80, chargepilot://topup, chargepilot://cycle, chargepilot://calibrate, chargepilot://pause.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Diagnostic SMC") {
                HStack {
                    TextField("Clé", text: $key).frame(width: 80)
                    Button("Lire") {
                        Task { smcOutput = (try? await model.client.smcRead(key)) ?? "assistant injoignable" }
                    }
                    Text(smcOutput).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let native = model.nativeLimit {
                    Text("Limite native de macOS actuellement à \(native) %.\(caps.nativeSteps.isEmpty ? "" : " ChargePilot la règle lui-même ; inutile de la changer dans Réglages Système.")").font(.caption)
                }
                Text("Si un autre outil de limitation de charge est installé, quittez-le : deux outils qui pilotent la même batterie se contredisent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("ChargePilot") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch model.helperStatus {
        case .checking: return "Vérification…"
        case .notInstalled: return "Non installé"
        case .unreachable(let message): return "Injoignable (\(message))"
        case .outdated: return "À mettre à jour"
        case .running: return "Actif"
        }
    }
}
