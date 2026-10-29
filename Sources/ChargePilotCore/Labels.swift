import Foundation

public extension ChargeStatus {
    var label: String {
        switch self {
        case .onBattery: return "Sur batterie"
        case .charging: return "En charge"
        case .limitReached: return "Limite atteinte"
        case .sailing: return "Navigation"
        case .discharging: return "Décharge"
        case .heatProtection: return "Protection thermique"
        case .full: return "Chargée"
        case .disabled: return "En pause — macOS gère la charge"
        case .notInstalled: return "Assistant non installé"
        }
    }
}

public extension ChargeMode {
    var label: String {
        switch self {
        case .normal: return "Limite"
        case .topUp: return "Recharge à 100 %"
        case .discharge(let target): return "Décharge jusqu'à \(target) %"
        case .calibration(let phase, _): return "Calibration — \(phase.label)"
        case .cycle(let low, let high, let draining, _):
            return draining ? "Cycles — décharge jusqu'à \(low) %" : "Cycles — charge jusqu'à \(high) %"
        }
    }

    var isTask: Bool { self != .normal }
}

public extension CalibrationPhase {
    var label: String {
        switch self {
        case .dischargeLow: return "décharge"
        case .chargeFull: return "charge à 100 %"
        case .holdFull: return "maintien à 100 %"
        case .dischargeToLimit: return "retour à la limite"
        }
    }

    var step: Int {
        switch self {
        case .dischargeLow: return 1
        case .chargeFull: return 2
        case .holdFull: return 3
        case .dischargeToLimit: return 4
        }
    }
}

public extension MagSafeLEDMode {
    var label: String {
        switch self {
        case .system: return "Laisser macOS gérer"
        case .automatic: return "Automatique (vert à la limite)"
        case .off: return "Éteinte"
        case .green: return "Toujours verte"
        case .amber: return "Toujours orange"
        }
    }
}

public extension ScheduledAction {
    var label: String {
        switch self {
        case .topUp: return "Recharger à 100 %"
        case .discharge: return "Décharger jusqu'à"
        case .calibrate: return "Calibrer"
        case .cycle: return "Démarrer les cycles"
        case .setLimit: return "Changer la limite à"
        case .pause: return "Mettre en pause"
        case .resume: return "Reprendre"
        }
    }

    var takesValue: Bool { self == .discharge || self == .setLimit }
}

public extension HelperEvent {
    /// Title and body for a user notification, or nil for events that don't warrant one.
    var notification: (title: String, body: String)? {
        switch kind {
        case .limitReached: return ("Limite atteinte", "La batterie est à \(detail) % ; la charge est suspendue.")
        case .topUpDone: return ("Batterie pleine", "La recharge à 100 % est terminée. La limite reviendra au débranchement.")
        case .dischargeDone: return ("Décharge terminée", "La batterie est à \(detail) % ; le secteur reprend le relais.")
        case .calibrationPhase:
            let phase = CalibrationPhase(rawValue: detail)
            return ("Calibration", "Étape \(phase?.step ?? 0)/4 : \(phase?.label ?? detail).")
        case .calibrationDone: return ("Calibration terminée", "La batterie est revenue à la limite de charge.")
        case .heatPaused: return ("Batterie chaude", "Charge suspendue à \(detail) °C.")
        case .heatResumed: return ("Température revenue", "La charge reprend (\(detail) °C).")
        case .cycleDrain: return ("Cycles", "Recharge terminée (\(detail) %) ; le Mac repasse sur batterie.")
        case .cycleCharge: return ("Cycles", "Batterie à \(detail) % ; la recharge reprend.")
        case .cycleStopped: return ("Cycles arrêtés", "Le Mac a été débranché ; retour à la limite de charge.")
        case .scheduleRan: return nil
        }
    }
}
