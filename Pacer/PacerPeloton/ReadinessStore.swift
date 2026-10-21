//
//  ReadinessStore.swift
//  PacerPeloton
//
//  Persists readiness check history and maintains rolling baselines
//  via exponential moving averages (EMA). First-check bootstrapping
//  uses sensible population defaults so the system works from day one.
//

import Foundation

// MARK: - Rolling Baselines

/// Exponential moving averages of each readiness signal.
struct ReadinessBaselines: Codable {
    /// Baseline sitting HR (bpm).
    var sittingHR: Double

    /// Baseline sit→stand delta (bpm).
    var orthostaticDelta: Double

    /// Baseline easy-effort HR (bpm).
    var easyEffortHR: Double

    /// How many checks have been incorporated.
    var checkCount: Int

    /// Population defaults for bootstrapping (before any personal data).
    static let defaults = ReadinessBaselines(
        sittingHR: 68,
        orthostaticDelta: 15,
        easyEffortHR: 110,
        checkCount: 0
    )

    /// EMA smoothing factor. α = 2 / (N + 1).
    /// With N = 10 we weight the last ~10 checks most heavily,
    /// responding to real shifts without overreacting to one bad day.
    private static let alpha: Double = 2.0 / 11.0   // ≈ 0.182

    /// Update baselines with a new check's raw values.
    mutating func incorporate(sittingHR: Double, orthostaticDelta: Double, easyEffortHR: Double) {
        if checkCount == 0 {
            // First check — seed the baselines with actual values.
            self.sittingHR = sittingHR
            self.orthostaticDelta = orthostaticDelta
            self.easyEffortHR = easyEffortHR
        } else {
            let a = Self.alpha
            self.sittingHR         = a * sittingHR         + (1 - a) * self.sittingHR
            self.orthostaticDelta  = a * orthostaticDelta  + (1 - a) * self.orthostaticDelta
            self.easyEffortHR      = a * easyEffortHR      + (1 - a) * self.easyEffortHR
        }
        checkCount += 1
    }
}

// MARK: - Readiness Store

/// Singleton that persists readiness checks and baselines to UserDefaults.
final class ReadinessStore {
    static let shared = ReadinessStore()

    private let checksKey    = "readinessChecks"
    private let baselinesKey = "readinessBaselines"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    // MARK: - Baselines

    /// Current rolling baselines. Returns population defaults if none saved.
    var baselines: ReadinessBaselines {
        get {
            guard let data = UserDefaults.standard.data(forKey: baselinesKey),
                  let b = try? decoder.decode(ReadinessBaselines.self, from: data)
            else { return .defaults }
            return b
        }
        set {
            if let data = try? encoder.encode(newValue) {
                UserDefaults.standard.set(data, forKey: baselinesKey)
            }
        }
    }

    // MARK: - Check History

    /// All saved readiness checks, newest first.
    var checks: [ReadinessCheck] {
        get {
            guard let data = UserDefaults.standard.data(forKey: checksKey),
                  let list = try? decoder.decode([ReadinessCheck].self, from: data)
            else { return [] }
            return list.sorted { $0.date > $1.date }
        }
        set {
            if let data = try? encoder.encode(newValue) {
                UserDefaults.standard.set(data, forKey: checksKey)
            }
        }
    }

    /// The most recent check, if any.
    var latestCheck: ReadinessCheck? {
        checks.first
    }

    /// Whether a check has been done today.
    var hasCheckedToday: Bool {
        guard let latest = latestCheck else { return false }
        return Calendar.current.isDateInToday(latest.date)
    }

    // MARK: - Record a Completed Check

    /// Scores a new check, updates baselines, persists both, and returns the result.
    @discardableResult
    func record(sittingHR: Double, standingHR: Double, easyEffortHR: Double,
                updateBaselines: Bool = true) -> ReadinessCheck {
        let currentBaselines = baselines
        let level = scoreReadiness(
            sittingHR: sittingHR,
            standingHR: standingHR,
            easyEffortHR: easyEffortHR,
            baselines: currentBaselines
        )

        let check = ReadinessCheck(
            sittingHR: sittingHR,
            standingHR: standingHR,
            easyEffortHR: easyEffortHR,
            level: level
        )

        // Persist the check
        var history = checks
        history.insert(check, at: 0)
        // Keep last 90 days of checks
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        history.removeAll { $0.date < cutoff }
        checks = history

        // Update baselines with this check's raw values — skipped when a
        // phase had no real readings, so estimates never skew the baselines.
        guard updateBaselines else { return check }
        var b = currentBaselines
        b.incorporate(
            sittingHR: sittingHR,
            orthostaticDelta: check.orthostaticDelta,
            easyEffortHR: easyEffortHR
        )
        baselines = b

        return check
    }

    // MARK: - Reset

    /// Clears all readiness data (checks + baselines). Used in testing or full reset.
    func resetAll() {
        UserDefaults.standard.removeObject(forKey: checksKey)
        UserDefaults.standard.removeObject(forKey: baselinesKey)
    }
}
