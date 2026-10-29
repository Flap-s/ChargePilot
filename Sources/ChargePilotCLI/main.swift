import Foundation
import ChargePilotCore

let usage = """
usage : chargepilot <commande>

  status              état de la batterie et de l'assistant
  json                état complet en JSON
  limit <20-100>      fixe la limite de charge
  topup               charge jusqu'à 100 % (jusqu'au débranchement)
  discharge [cible]   décharge sur secteur jusqu'à la cible (la limite par défaut)
  calibrate           lance une calibration
  cycles [bas haut]   décharge jusqu'au seuil bas, recharge jusqu'au haut, et recommence (dock)
  cancel              annule la recharge, la décharge ou la calibration en cours
  pause | resume      rend la main à macOS / reprend la limitation
  sailing on|off [écart]
  heat on|off [°C]    protection thermique
  led system|auto|off|green|amber
  lowpower on|off     mode économie d'énergie
  highpower on|off    mode haute puissance (Mac compatibles)
  smc read <clé>      diagnostic
  smc write <clé> <hex>
  hardware <json>|reset  méthode de coupure personnalisée, ex.
                      '{"chargeInhibit":{"keys":["CHIE"],"on":"01","off":"00"}}'
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func onOff(_ value: String?) -> Bool {
    switch value?.lowercased() {
    case "on", "1", "true", "oui": return true
    case "off", "0", "false", "non": return false
    default: fail(usage)
    }
}

let client = HelperClient()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

func updateConfig(_ change: (inout ChargeConfig) -> Void) async throws {
    var config = try await client.state().config
    change(&config)
    try await client.setConfig(config)
}

do {
    switch command {
    case "status":
        let battery = BatteryReader.read()
        print("Batterie : \(battery.percent) % (matériel \(String(format: "%.1f", battery.hardwarePercent)) %)")
        print("Secteur : \(battery.externalConnected ? "branché" : "débranché")\(battery.isCharging ? ", en charge" : "")")
        if let health = battery.health { print("Santé : \(String(format: "%.1f", health)) % · \(battery.cycleCount) cycles") }
        if let t = battery.temperature { print("Température : \(String(format: "%.1f", t)) °C") }
        print(String(format: "Puissance batterie : %+.1f W", battery.batteryPower))
        do {
            let state = try await client.state()
            print("Limite : \(state.config.limit) % — \(state.status.label)")
            print("Mode : \(state.mode.label)")
            print("Charge suspendue : \(state.chargingInhibited ? "oui" : "non") · adaptateur coupé : \(state.adapterDisabled ? "oui" : "non")")
            if let error = state.lastError { print("Erreur : \(error)") }
        } catch {
            print("Assistant : non joignable (\(error.localizedDescription))")
        }
    case "json":
        let state = try await client.state()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))
    case "limit":
        guard let value = args.first.flatMap(Int.init) else { fail(usage) }
        try await client.perform(.setLimit, value: value)
    case "topup": try await client.perform(.topUp)
    case "discharge": try await client.perform(.discharge, value: args.first.flatMap(Int.init) ?? 0)
    case "calibrate": try await client.perform(.calibrate)
    case "cycles", "cycle":
        if args.count == 2, let low = Int(args[0]), let high = Int(args[1]) {
            try await updateConfig { $0.cycleLow = low; $0.cycleHigh = high }
        }
        try await client.perform(.cycle)
    case "cancel": try await client.perform(.cancel)
    case "pause": try await client.perform(.pause)
    case "resume": try await client.perform(.resume)
    case "sailing":
        let on = onOff(args.first)
        try await updateConfig {
            $0.sailing = on
            if let gap = args.dropFirst().first.flatMap(Int.init) { $0.sailingGap = gap }
        }
    case "heat":
        let on = onOff(args.first)
        try await updateConfig {
            $0.heatProtection = on
            if let t = args.dropFirst().first.flatMap(Double.init) { $0.heatThreshold = t }
        }
    case "led":
        let mode: MagSafeLEDMode
        switch args.first {
        case "system": mode = .system
        case "auto": mode = .automatic
        case "off": mode = .off
        case "green": mode = .green
        case "amber", "orange": mode = .amber
        default: fail(usage)
        }
        try await updateConfig { $0.magSafeLED = mode }
    case "lowpower": try await client.perform(.lowPowerMode, value: onOff(args.first) ? 1 : 0)
    case "highpower": try await client.perform(.highPowerMode, value: onOff(args.first) ? 1 : 0)
    case "smc":
        guard args.count >= 2 else { fail(usage) }
        if args[0] == "read" {
            print(try await client.smcRead(args[1]))
        } else if args[0] == "write", args.count == 3 {
            try await client.smcWrite(args[1], hex: args[2])
            print(try await client.smcRead(args[1]))
        } else {
            fail(usage)
        }
    case "hardware":
        guard let argument = args.first else { fail(usage) }
        try await client.setHardwareOverride(argument == "reset" ? Data() : Data(argument.utf8))
        print(try await client.state().capabilities)
    default:
        fail(usage)
    }
} catch {
    fail(error.localizedDescription)
}
