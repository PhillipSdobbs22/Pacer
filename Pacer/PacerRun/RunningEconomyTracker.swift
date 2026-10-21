//
//  RunningEconomyTracker.swift
//  PacerRun
//
//  Tracks Running Economy via Cardiac Cost Index (CCI = HR ÷ Speed).
//  Lower CCI = better economy (less cardiac effort per unit of speed).
//  Computes per-interval CCI, detects trend across intervals,
//  and accumulates overall workout CCI.
//
//  Designed for Apple Watch SE 1st gen (HR + GPS only).
//

import Foundation

/// Running Economy trend across successive 3-minute intervals.
enum RETrend: String {
    case improving = "improving"   // CCI dropping (getting more efficient)
    case steady    = "steady"      // CCI within ±5 % of previous
    case fading    = "fading"      // CCI rising  (getting less efficient)
    case none      = ""            // not enough data yet
}

/// Snapshot of RE stats for a single interval.
struct REIntervalResult {
    let intervalNumber: Int        // 1-based
    let cci: Double                // HR ÷ speed (bpm / mph)
    let avgHR: Double
    let avgSpeedMPH: Double
    let avgSPM: Double             // steps per minute this interval
    let trend: RETrend
}

/// A single interval's SPM-CCI pair for correlation analysis.
struct SPMCCIPair {
    let spm: Double
    let cci: Double
}

/// Overall workout RE summary, exposed to the summary screen.
struct RESummary {
    let overallCCI: Double         // whole-workout average CCI
    let bestIntervalCCI: Double    // lowest (most efficient)
    let worstIntervalCCI: Double   // highest (least efficient)
    let bestIntervalNumber: Int
    let worstIntervalNumber: Int
    let finalTrend: RETrend
    let intervalCount: Int
    let spmCCIPairs: [SPMCCIPair]  // per-interval (SPM, CCI) for correlation
    let overallAvgSPM: Double      // session-wide average steps per minute
}

@MainActor
final class RunningEconomyTracker {

    // MARK: - Configuration

    /// User's body weight in pounds (set before workout starts).
    /// Used for weight-normalized CCI on the summary screen.
    var bodyWeightLbs: Double = 197.0

    /// Baseline weight for normalization (the weight at which
    /// raw CCI and normalized CCI are equal).
    var baselineWeightLbs: Double = 197.0

    // MARK: - Interval State

    /// CCI values for each completed interval (for trend + best/worst).
    private(set) var intervalResults: [REIntervalResult] = []

    /// Accumulated HR, speed, and SPM samples within the current interval.
    private var currentHRSamples: [Double] = []
    private var currentSpeedSamples: [Double] = []
    private var currentSPMSamples: [Double] = []

    // MARK: - Overall Accumulator

    /// All HR, speed, and SPM samples across the entire workout,
    /// used to compute overall CCI and SPM at save time.
    private var allHRSamples: [Double] = []
    private var allSpeedSamples: [Double] = []
    private var allSPMSamples: [Double] = []

    // MARK: - Public API

    /// Call at workout start to reset everything.
    func reset() {
        intervalResults.removeAll()
        currentHRSamples.removeAll()
        currentSpeedSamples.removeAll()
        currentSPMSamples.removeAll()
        allHRSamples.removeAll()
        allSpeedSamples.removeAll()
        allSPMSamples.removeAll()
    }

    /// Feed a heart-rate sample (called every time HK delivers a new BPM).
    func addHRSample(_ bpm: Double) {
        guard bpm > 0 else { return }
        currentHRSamples.append(bpm)
        allHRSamples.append(bpm)
    }

    /// Feed a speed sample (called every GPS update, in mph).
    func addSpeedSample(_ mph: Double) {
        guard mph > 0.3 else { return }   // ignore near-standstill
        currentSpeedSamples.append(mph)
        allSpeedSamples.append(mph)
    }

    /// Feed a steps-per-minute sample (called on each step-count update).
    func addSPMSample(_ spm: Double) {
        guard spm > 0 else { return }
        currentSPMSamples.append(spm)
        allSPMSamples.append(spm)
    }

    /// Close the current interval, compute its CCI, detect trend,
    /// store the result, and reset interval accumulators.
    /// Returns the interval result (or nil if not enough data).
    @discardableResult
    func closeInterval() -> REIntervalResult? {
        guard !currentHRSamples.isEmpty,
              !currentSpeedSamples.isEmpty else {
            // Not enough data — skip this interval silently
            currentHRSamples.removeAll()
            currentSpeedSamples.removeAll()
            currentSPMSamples.removeAll()
            return nil
        }

        let avgHR = currentHRSamples.reduce(0, +)
            / Double(currentHRSamples.count)
        let avgSpeed = currentSpeedSamples.reduce(0, +)
            / Double(currentSpeedSamples.count)
        let avgSPM: Double = currentSPMSamples.isEmpty
            ? 0
            : currentSPMSamples.reduce(0, +) / Double(currentSPMSamples.count)

        let cci = avgHR / avgSpeed   // bpm per mph — lower is better

        // Detect trend vs. previous interval
        let trend: RETrend
        if let prev = intervalResults.last {
            let change = (cci - prev.cci) / prev.cci  // positive = worsening
            if change < -0.05 {
                trend = .improving
            } else if change > 0.05 {
                trend = .fading
            } else {
                trend = .steady
            }
        } else {
            trend = .none  // first interval — no comparison
        }

        let result = REIntervalResult(
            intervalNumber: intervalResults.count + 1,
            cci: cci,
            avgHR: avgHR,
            avgSpeedMPH: avgSpeed,
            avgSPM: avgSPM,
            trend: trend
        )
        intervalResults.append(result)

        // Reset for next interval
        currentHRSamples.removeAll()
        currentSpeedSamples.removeAll()
        currentSPMSamples.removeAll()

        return result
    }

    /// The most recent interval's CCI (for the audio announcement).
    var latestCCI: Double? {
        intervalResults.last?.cci
    }

    /// The most recent trend word.
    var latestTrend: RETrend {
        intervalResults.last?.trend ?? .none
    }

    // MARK: - Overall Summary (called at save time)

    /// Builds the full-workout RE summary for the results screen.
    func buildSummary() -> RESummary? {
        guard !intervalResults.isEmpty else { return nil }

        // Overall CCI from ALL samples (not just interval averages)
        let overallCCI: Double
        if !allHRSamples.isEmpty && !allSpeedSamples.isEmpty {
            let totalAvgHR = allHRSamples.reduce(0, +)
                / Double(allHRSamples.count)
            let totalAvgSpeed = allSpeedSamples.reduce(0, +)
                / Double(allSpeedSamples.count)
            overallCCI = totalAvgHR / totalAvgSpeed
        } else {
            overallCCI = intervalResults
                .map(\.cci).reduce(0, +)
                / Double(intervalResults.count)
        }

        let best = intervalResults.min(by: { $0.cci < $1.cci })!
        let worst = intervalResults.max(by: { $0.cci < $1.cci })!

        // Build per-interval SPM-CCI pairs for correlation analysis
        let spmCCIPairs = intervalResults.map {
            SPMCCIPair(spm: $0.avgSPM, cci: $0.cci)
        }

        // Overall average SPM from all samples
        let overallAvgSPM: Double = allSPMSamples.isEmpty
            ? 0
            : allSPMSamples.reduce(0, +) / Double(allSPMSamples.count)

        return RESummary(
            overallCCI: overallCCI,
            bestIntervalCCI: best.cci,
            worstIntervalCCI: worst.cci,
            bestIntervalNumber: best.intervalNumber,
            worstIntervalNumber: worst.intervalNumber,
            finalTrend: intervalResults.last?.trend ?? .none,
            intervalCount: intervalResults.count,
            spmCCIPairs: spmCCIPairs,
            overallAvgSPM: overallAvgSPM
        )
    }

    /// Weight-normalized CCI:  raw CCI × (currentWeight / baselineWeight).
    /// When you weigh more than baseline, normalized CCI rises — separating
    /// body-mass cost from cardio fitness.  When you lose weight to baseline,
    /// normalized CCI equals raw CCI.
    func weightNormalizedCCI(_ rawCCI: Double) -> Double {
        guard baselineWeightLbs > 0 else { return rawCCI }
        return rawCCI * (bodyWeightLbs / baselineWeightLbs)
    }
}
