//
//  ReadinessCheck.swift
//  PacerPeloton
//
//  Pre-ride readiness check model — Heikki Rusko orthostatic protocol.
//  Captures sitting HR, standing HR, and easy-effort HR, then scores
//  the rider's autonomic readiness as Fresh / Normal / Fatigued.
//

import Foundation

// MARK: - Readiness Level

enum ReadinessLevel: String, Codable, CaseIterable {
    case fresh    = "Fresh"
    case normal   = "Normal"
    case fatigued = "Fatigued"

    var emoji: String {
        switch self {
        case .fresh:    return "🟢"
        case .normal:   return "🟡"
        case .fatigued: return "🔴"
        }
    }

    /// Short recommendation string shown on the results screen.
    var recommendation: String {
        switch self {
        case .fresh:
            return "You're primed — chase both ghosts today!"
        case .normal:
            return "Solid day — the Hare is your target."
        case .fatigued:
            return "Recovery ride — just stay ahead of the Tortoise."
        }
    }

    /// Which ghosts should be active for this readiness level.
    /// Returns the GhostRole cases that should be enabled.
    var activeRoles: Set<String> {
        switch self {
        case .fresh:    return ["rabbit", "hound"]
        case .normal:   return ["rabbit"]
        case .fatigued: return ["hound"]
        }
    }
}

// MARK: - Readiness Check Result

/// A single completed readiness check.
struct ReadinessCheck: Codable, Identifiable {
    let id: UUID
    let date: Date

    /// Average HR during the 2-minute sitting phase (bpm).
    let sittingHR: Double

    /// Average HR during the 1-minute standing phase (bpm).
    let standingHR: Double

    /// Average HR during the 4-minute easy-pedaling phase (bpm).
    let easyEffortHR: Double

    /// Computed sit→stand delta.
    var orthostaticDelta: Double {
        standingHR - sittingHR
    }

    /// The scored readiness level.
    let level: ReadinessLevel

    init(sittingHR: Double, standingHR: Double, easyEffortHR: Double, level: ReadinessLevel) {
        self.id = UUID()
        self.date = Date()
        self.sittingHR = sittingHR
        self.standingHR = standingHR
        self.easyEffortHR = easyEffortHR
        self.level = level
    }
}

// MARK: - Signal Scoring

/// Individual signal assessment used during scoring.
enum SignalScore: String {
    case fresh    = "Fresh"
    case normal   = "Normal"
    case fatigued = "Fatigued"
}

/// Scores three signals against personal baselines and returns a ReadinessLevel.
func scoreReadiness(
    sittingHR: Double,
    standingHR: Double,
    easyEffortHR: Double,
    baselines: ReadinessBaselines
) -> ReadinessLevel {

    let orthostaticDelta = standingHR - sittingHR

    // --- Signal 1: Resting HR vs baseline ---
    let restingSignal: SignalScore
    if sittingHR <= baselines.sittingHR {
        restingSignal = .fresh
    } else if sittingHR <= baselines.sittingHR + 5 {
        restingSignal = .normal
    } else {
        restingSignal = .fatigued
    }

    // --- Signal 2: Orthostatic delta vs baseline delta ---
    let deltaSignal: SignalScore
    if orthostaticDelta <= baselines.orthostaticDelta {
        deltaSignal = .fresh
    } else if orthostaticDelta <= baselines.orthostaticDelta + 5 {
        deltaSignal = .normal
    } else {
        deltaSignal = .fatigued
    }

    // --- Signal 3: Easy-effort HR vs baseline ---
    let effortSignal: SignalScore
    if easyEffortHR <= baselines.easyEffortHR {
        effortSignal = .fresh
    } else if easyEffortHR <= baselines.easyEffortHR + 5 {
        effortSignal = .normal
    } else {
        effortSignal = .fatigued
    }

    // --- Aggregate ---
    let signals = [restingSignal, deltaSignal, effortSignal]
    let fatiguedCount = signals.filter { $0 == .fatigued }.count
    let freshCount    = signals.filter { $0 == .fresh }.count

    if fatiguedCount >= 2 {
        return .fatigued
    } else if freshCount >= 2 {
        return .fresh
    } else {
        return .normal
    }
}
