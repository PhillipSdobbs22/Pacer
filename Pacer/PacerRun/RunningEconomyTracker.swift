//
//  RunningEconomyTracker.swift
//  PacerRun
//
//  Tracks Running Economy via Cardiac Cost Index (CCI = HR ÷ Speed).
//  Lower CCI = better economy (less cardiac effort per unit of speed).
//
//  === Stability Gate ===
//  Only emits auto-interval data when BOTH speed and heart rate are
//  stable.  Walk↔jog transitions cause a ~30-90 s cardiovascular lag
//  where HR doesn't reflect the current pace — those transient periods
//  produce unreliable CCI values and are excluded.
//
//  Gate logic:
//  1. Raw speed/HR pass through sanity bounds, then a median-of-3 filter
//     (rejects single-sample spikes without needing a look-ahead).
//  2. Filtered speed enters a 15-second rolling window.  Speed is
//     "settled" when the rolling average hasn't shifted >1 mph from
//     the established pace for ≥5 seconds of real (sustained) change.
//  3. Filtered HR enters a 30-second rolling window.  HR is "settled"
//     when the range of the window is <10 bpm.
//  4. An interval clock only runs while BOTH are settled.
//  5. At 180 seconds of accumulated stable time → interval fires,
//     clock resets.
//  6. Any transition (speed shift >1 mph sustained >5 s) → clock
//     resets to zero, discarding partial data.
//
//  Manual intervals:
//  - User presses INTERVAL button to start/stop.
//  - Anomaly filter applies, stability gate does NOT.
//  - Tagged as source: "manual" in saved data.
//

import Foundation

// MARK: - RE Trend

/// Running Economy trend across successive intervals.
enum RETrend: String {
    case improving = "improving"
    case steady    = "steady"
    case fading    = "fading"
    case none      = ""
}

// MARK: - Interval Result

/// Snapshot of RE stats for a single completed interval.
struct REIntervalResult {
    let intervalNumber: Int
    let cci: Double
    let avgHR: Double
    let avgSpeedMPH: Double
    let avgSPM: Double
    let trend: RETrend
    let source: String        // "auto" or "manual"
}

// MARK: - SPM-CCI Pair

/// A single interval's SPM-CCI pair for cross-run correlation analysis.
struct SPMCCIPair {
    let spm: Double
    let cci: Double
    let avgSpeedMPH: Double
    let source: String        // "auto" or "manual"
    let isStable: Bool        // true for stability-gated auto intervals
}

// MARK: - Time-Series Sample

/// A single point-in-time snapshot recorded every ~10 seconds for
/// post-run analysis.  Lightweight: 5 numbers per sample ≈ 40 bytes.
struct TimeSeriesSample {
    let elapsed: TimeInterval     // seconds since workout start
    let spm: Double               // steps per minute (0 if no data yet)
    let hr: Double                // heart rate bpm (0 if no data yet)
    let speedMPH: Double          // speed in mph (0 if no data yet)
    let isStable: Bool            // stability gate open at this moment
}

// MARK: - RE Summary

/// Overall workout RE summary for the results screen.
struct RESummary {
    let overallCCI: Double
    let bestIntervalCCI: Double
    let worstIntervalCCI: Double
    let bestIntervalNumber: Int
    let worstIntervalNumber: Int
    let finalTrend: RETrend
    let intervalCount: Int
    let spmCCIPairs: [SPMCCIPair]
    let overallAvgSPM: Double
    let timeSeries: [TimeSeriesSample]
}

// MARK: - Private Types

private enum StabilityState {
    case unstable
    case stable
}

private struct TimestampedSample {
    let value: Double
    let time: Date
}

// MARK: - RunningEconomyTracker

@MainActor
final class RunningEconomyTracker {

    // ───────────────────────────────────────────────────────────
    // MARK: - Configuration
    // ───────────────────────────────────────────────────────────

    var bodyWeightLbs: Double = 197.0
    var baselineWeightLbs: Double = 197.0

    /// Fires when a stability-gated 3-minute interval completes.
    var onStableIntervalComplete: ((REIntervalResult) -> Void)?

    /// Fires when a manual interval is stopped by the user.
    var onManualIntervalComplete: ((REIntervalResult) -> Void)?

    // ───────────────────────────────────────────────────────────
    // MARK: - Stability Gate Tuning Constants
    // ───────────────────────────────────────────────────────────

    /// Rolling window for speed averaging (seconds).
    private let speedWindowDuration: TimeInterval = 15.0

    /// Rolling window for HR settling (seconds).
    private let hrWindowDuration: TimeInterval = 30.0

    /// Speed shift threshold for detecting a walk↔jog transition (mph).
    private let speedChangeThreshold: Double = 1.0

    /// HR range must be within this to count as "settled" (bpm).
    private let hrSettledRange: Double = 10.0

    /// How long speed must stay within threshold before counting as
    /// settled — filters out GPS jitter shorter than this (seconds).
    private let speedSettleDelay: TimeInterval = 5.0

    /// Stable time required to fire an automatic interval (seconds).
    private let stableIntervalDuration: TimeInterval = 180.0

    /// Sanity bounds — anything outside is discarded immediately.
    private let speedMin: Double = 0.3
    private let speedMax: Double = 15.0
    private let hrMin: Double = 40.0
    private let hrMax: Double = 220.0

    // ───────────────────────────────────────────────────────────
    // MARK: - Interval Results
    // ───────────────────────────────────────────────────────────

    private(set) var intervalResults: [REIntervalResult] = []

    // ───────────────────────────────────────────────────────────
    // MARK: - Stability Gate Internal State
    // ───────────────────────────────────────────────────────────

    private var stabilityState: StabilityState = .unstable
    private var gatePaused: Bool = false

    /// Rolling windows (trimmed to their duration on each insertion).
    private var speedWindow: [TimestampedSample] = []
    private var hrWindow: [TimestampedSample] = []

    /// Median-of-3 input buffers (last 3 raw samples).
    private var recentRawSpeeds: [Double] = []
    private var recentRawHRs: [Double] = []

    /// The rolling speed average when stability was last achieved.
    /// Used as the "established pace" reference.
    private var stableSpeedReference: Double? = nil

    /// When speed first settled at the current pace.
    private var speedSettledSince: Date? = nil

    /// Accumulated stable time toward the next auto interval.
    private var stableTimeAccumulated: TimeInterval = 0.0

    /// Timestamp of last stability tick (for delta calculation).
    private var lastStableTick: Date? = nil

    // ───────────────────────────────────────────────────────────
    // MARK: - Interval Sample Accumulators (stable time only)
    // ───────────────────────────────────────────────────────────

    private var currentHRSamples: [Double] = []
    private var currentSpeedSamples: [Double] = []
    private var currentSPMSamples: [Double] = []

    // ───────────────────────────────────────────────────────────
    // MARK: - Overall Accumulators (entire workout, all samples)
    // ───────────────────────────────────────────────────────────

    private var allHRSamples: [Double] = []
    private var allSpeedSamples: [Double] = []
    private var allSPMSamples: [Double] = []

    // ───────────────────────────────────────────────────────────
    // MARK: - Time-Series Logger (10-second snapshots)
    // ───────────────────────────────────────────────────────────

    private let snapshotInterval: TimeInterval = 10.0
    private var timeSeriesSamples: [TimeSeriesSample] = []
    private var lastSnapshotTime: Date? = nil
    private var workoutStartDate: Date? = nil

    /// Most recent filtered values (updated on every sample ingestion).
    private var latestFilteredHR: Double = 0
    private var latestFilteredSpeed: Double = 0
    private var latestFilteredSPM: Double = 0

    // ───────────────────────────────────────────────────────────
    // MARK: - Manual Interval State
    // ───────────────────────────────────────────────────────────

    private(set) var isManualIntervalActive: Bool = false
    private var manualHRSamples: [Double] = []
    private var manualSpeedSamples: [Double] = []
    private var manualSPMSamples: [Double] = []

    // ═══════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════

    /// Reset everything for a new workout.
    func reset() {
        intervalResults.removeAll()

        stabilityState = .unstable
        gatePaused = false
        speedWindow.removeAll()
        hrWindow.removeAll()
        recentRawSpeeds.removeAll()
        recentRawHRs.removeAll()
        stableSpeedReference = nil
        speedSettledSince = nil
        stableTimeAccumulated = 0
        lastStableTick = nil

        currentHRSamples.removeAll()
        currentSpeedSamples.removeAll()
        currentSPMSamples.removeAll()

        allHRSamples.removeAll()
        allSpeedSamples.removeAll()
        allSPMSamples.removeAll()

        timeSeriesSamples.removeAll()
        lastSnapshotTime = nil
        workoutStartDate = nil
        latestFilteredHR = 0
        latestFilteredSpeed = 0
        latestFilteredSPM = 0

        isManualIntervalActive = false
        manualHRSamples.removeAll()
        manualSpeedSamples.removeAll()
        manualSPMSamples.removeAll()
    }

    /// Pause the stability gate (call when workout is paused).
    func pause() {
        gatePaused = true
        lastStableTick = nil
        lastSnapshotTime = nil   // gap in snapshots while paused
    }

    /// Resume the stability gate (call when workout resumes).
    func resume() {
        gatePaused = false
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Sample Ingestion
    // ───────────────────────────────────────────────────────────

    /// Feed a heart-rate sample (bpm).
    func addHRSample(_ bpm: Double) {
        guard !gatePaused else { return }
        let now = Date()

        // 1. Sanity bounds
        guard bpm >= hrMin && bpm <= hrMax else { return }

        // 2. Median-of-3 spike filter
        recentRawHRs.append(bpm)
        if recentRawHRs.count > 3 { recentRawHRs.removeFirst() }
        let filtered = median(recentRawHRs)

        // 3. Rolling window
        hrWindow.append(TimestampedSample(value: filtered, time: now))
        trimWindow(&hrWindow, duration: hrWindowDuration, now: now)

        // 3a. Update latest filtered value for time-series snapshots
        latestFilteredHR = filtered

        // 4. Overall accumulator
        allHRSamples.append(filtered)

        // 5. Manual interval (no stability gate needed)
        if isManualIntervalActive {
            manualHRSamples.append(filtered)
        }

        // 6. Stable-interval accumulator (only while gate is open)
        if stabilityState == .stable {
            currentHRSamples.append(filtered)
        }

        // 7. Re-evaluate stability
        evaluateStability(now: now)
    }

    /// Feed a speed sample (mph).
    func addSpeedSample(_ mph: Double) {
        guard !gatePaused else { return }
        let now = Date()

        // 1. Sanity bounds
        guard mph >= speedMin && mph <= speedMax else { return }

        // 2. Median-of-3 spike filter
        recentRawSpeeds.append(mph)
        if recentRawSpeeds.count > 3 { recentRawSpeeds.removeFirst() }
        let filtered = median(recentRawSpeeds)

        // 3. Rolling window
        speedWindow.append(TimestampedSample(value: filtered, time: now))
        trimWindow(&speedWindow, duration: speedWindowDuration, now: now)

        // 3a. Update latest filtered value and check snapshot timer
        latestFilteredSpeed = filtered
        checkSnapshot(now: now)

        // 4. Overall accumulator
        allSpeedSamples.append(filtered)

        // 5. Manual interval
        if isManualIntervalActive {
            manualSpeedSamples.append(filtered)
        }

        // 6. Stable-interval accumulator
        if stabilityState == .stable {
            currentSpeedSamples.append(filtered)
        }

        // 7. Re-evaluate stability
        evaluateStability(now: now)
    }

    /// Feed a steps-per-minute sample.
    func addSPMSample(_ spm: Double) {
        guard !gatePaused, spm > 0 else { return }

        latestFilteredSPM = spm
        allSPMSamples.append(spm)

        if isManualIntervalActive {
            manualSPMSamples.append(spm)
        }
        if stabilityState == .stable {
            currentSPMSamples.append(spm)
        }
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Manual Interval
    // ───────────────────────────────────────────────────────────

    /// Start a manual interval (user pressed INTERVAL button).
    func startManualInterval() {
        guard !isManualIntervalActive else { return }
        isManualIntervalActive = true
        manualHRSamples.removeAll()
        manualSpeedSamples.removeAll()
        manualSPMSamples.removeAll()
    }

    /// Stop the manual interval and emit its result.
    @discardableResult
    func stopManualInterval() -> REIntervalResult? {
        guard isManualIntervalActive else { return nil }
        isManualIntervalActive = false

        guard !manualHRSamples.isEmpty,
              !manualSpeedSamples.isEmpty else {
            return nil
        }

        let avgHR = manualHRSamples.mean
        let avgSpeed = manualSpeedSamples.mean
        let avgSPM = manualSPMSamples.isEmpty ? 0.0 : manualSPMSamples.mean
        let cci = avgSpeed > 0 ? avgHR / avgSpeed : 0
        let trend = computeTrend(cci: cci)

        let result = REIntervalResult(
            intervalNumber: intervalResults.count + 1,
            cci: cci,
            avgHR: avgHR,
            avgSpeedMPH: avgSpeed,
            avgSPM: avgSPM,
            trend: trend,
            source: "manual"
        )
        intervalResults.append(result)

        manualHRSamples.removeAll()
        manualSpeedSamples.removeAll()
        manualSPMSamples.removeAll()

        onManualIntervalComplete?(result)
        return result
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - End-of-Workout Close
    // ───────────────────────────────────────────────────────────

    /// Close any in-progress interval at workout end.
    /// Requires at least 60 s of stable data to emit.
    @discardableResult
    func closeInterval() -> REIntervalResult? {
        if isManualIntervalActive { return stopManualInterval() }

        guard !currentHRSamples.isEmpty,
              !currentSpeedSamples.isEmpty,
              stableTimeAccumulated >= 60 else {
            currentHRSamples.removeAll()
            currentSpeedSamples.removeAll()
            currentSPMSamples.removeAll()
            return nil
        }

        let avgHR = currentHRSamples.mean
        let avgSpeed = currentSpeedSamples.mean
        let avgSPM = currentSPMSamples.isEmpty ? 0.0 : currentSPMSamples.mean
        let cci = avgSpeed > 0 ? avgHR / avgSpeed : 0
        let trend = computeTrend(cci: cci)

        let result = REIntervalResult(
            intervalNumber: intervalResults.count + 1,
            cci: cci,
            avgHR: avgHR,
            avgSpeedMPH: avgSpeed,
            avgSPM: avgSPM,
            trend: trend,
            source: "auto"
        )
        intervalResults.append(result)

        currentHRSamples.removeAll()
        currentSpeedSamples.removeAll()
        currentSPMSamples.removeAll()
        stableTimeAccumulated = 0

        return result
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Stability Evaluation (core gate logic)
    // ═══════════════════════════════════════════════════════════

    private func evaluateStability(now: Date) {
        let speedOK = isSpeedStable(now: now)
        let hrOK = isHRStable(now: now)
        let newState: StabilityState = (speedOK && hrOK) ? .stable : .unstable

        switch (stabilityState, newState) {

        case (.unstable, .stable):
            // Transition → stable: start counting
            stabilityState = .stable
            lastStableTick = now

        case (.stable, .stable):
            // Still stable — accumulate time
            if let tick = lastStableTick {
                let delta = min(now.timeIntervalSince(tick), 5.0)
                stableTimeAccumulated += delta
            }
            lastStableTick = now

            // Fire if we've hit 3 minutes of stable time
            if stableTimeAccumulated >= stableIntervalDuration {
                fireAutoInterval()
            }

        case (.stable, .unstable):
            // Lost stability — reset clock, discard partial samples
            stabilityState = .unstable
            stableTimeAccumulated = 0
            lastStableTick = nil
            currentHRSamples.removeAll()
            currentSpeedSamples.removeAll()
            currentSPMSamples.removeAll()

        case (.unstable, .unstable):
            break
        }
    }

    /// Speed is "settled" when the rolling 15 s average hasn't shifted
    /// more than `speedChangeThreshold` from the established reference
    /// for at least `speedSettleDelay` seconds.
    private func isSpeedStable(now: Date) -> Bool {
        guard speedWindow.count >= 2,
              let oldest = speedWindow.first,
              now.timeIntervalSince(oldest.time) >= speedSettleDelay
        else { return false }

        let rollingAvg = speedWindow.map(\.value).mean

        // Bootstrap reference on first call
        if stableSpeedReference == nil {
            stableSpeedReference = rollingAvg
            speedSettledSince = now
            return false
        }

        let deviation = abs(rollingAvg - stableSpeedReference!)

        if deviation > speedChangeThreshold {
            // Pace changed — update reference, restart settle timer
            stableSpeedReference = rollingAvg
            speedSettledSince = now
            return false
        }

        // Within threshold — check settle timer
        if speedSettledSince == nil { speedSettledSince = now }
        return now.timeIntervalSince(speedSettledSince!) >= speedSettleDelay
    }

    /// HR is "settled" when the range of values in the 30 s window
    /// is less than `hrSettledRange` bpm.  Allows a shorter window
    /// (≥15 s) as a preliminary check so the gate doesn't stay
    /// closed unnecessarily at workout start.
    private func isHRStable(now: Date) -> Bool {
        guard hrWindow.count >= 3,
              let oldest = hrWindow.first
        else { return false }

        let span = now.timeIntervalSince(oldest.time)
        guard span >= 15.0 else { return false }

        let values = hrWindow.map(\.value)
        let range = (values.max() ?? 0) - (values.min() ?? 0)
        return range < hrSettledRange
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Fire Auto Interval
    // ───────────────────────────────────────────────────────────

    private func fireAutoInterval() {
        guard !currentHRSamples.isEmpty,
              !currentSpeedSamples.isEmpty else {
            stableTimeAccumulated = 0
            return
        }

        let avgHR = currentHRSamples.mean
        let avgSpeed = currentSpeedSamples.mean
        let avgSPM = currentSPMSamples.isEmpty ? 0.0 : currentSPMSamples.mean
        let cci = avgSpeed > 0 ? avgHR / avgSpeed : 0
        let trend = computeTrend(cci: cci)

        let result = REIntervalResult(
            intervalNumber: intervalResults.count + 1,
            cci: cci,
            avgHR: avgHR,
            avgSpeedMPH: avgSpeed,
            avgSPM: avgSPM,
            trend: trend,
            source: "auto"
        )
        intervalResults.append(result)

        // Reset for next interval
        stableTimeAccumulated = 0
        currentHRSamples.removeAll()
        currentSpeedSamples.removeAll()
        currentSPMSamples.removeAll()

        onStableIntervalComplete?(result)
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Trend
    // ───────────────────────────────────────────────────────────

    private func computeTrend(cci: Double) -> RETrend {
        guard let prev = intervalResults.last else { return .none }
        guard prev.cci > 0 else { return .none }
        let change = (cci - prev.cci) / prev.cci
        if change < -0.05 { return .improving }
        if change >  0.05 { return .fading }
        return .steady
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ───────────────────────────────────────────────────────────

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private func trimWindow(_ window: inout [TimestampedSample],
                             duration: TimeInterval, now: Date) {
        let cutoff = now.addingTimeInterval(-duration)
        window.removeAll { $0.time < cutoff }
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Time-Series Snapshot
    // ───────────────────────────────────────────────────────────

    /// Takes a snapshot every ~10 seconds, piggy-backing on existing
    /// sample ingestion — no additional timer or sensor polling.
    private func checkSnapshot(now: Date) {
        // Bootstrap start time on first speed sample
        if workoutStartDate == nil { workoutStartDate = now }

        guard let start = workoutStartDate else { return }

        if let last = lastSnapshotTime {
            guard now.timeIntervalSince(last) >= snapshotInterval else { return }
        }
        // else: first snapshot

        let sample = TimeSeriesSample(
            elapsed: now.timeIntervalSince(start),
            spm: latestFilteredSPM,
            hr: latestFilteredHR,
            speedMPH: latestFilteredSpeed,
            isStable: stabilityState == .stable
        )
        timeSeriesSamples.append(sample)
        lastSnapshotTime = now
    }

    // ───────────────────────────────────────────────────────────
    // MARK: - Legacy / Convenience
    // ───────────────────────────────────────────────────────────

    var latestCCI: Double? { intervalResults.last?.cci }
    var latestTrend: RETrend { intervalResults.last?.trend ?? .none }

    // ───────────────────────────────────────────────────────────
    // MARK: - Summary
    // ───────────────────────────────────────────────────────────

    func buildSummary() -> RESummary? {
        guard !intervalResults.isEmpty else { return nil }

        let overallCCI: Double
        if !allHRSamples.isEmpty && !allSpeedSamples.isEmpty {
            let avgHR = allHRSamples.mean
            let avgSpeed = allSpeedSamples.mean
            overallCCI = avgSpeed > 0 ? avgHR / avgSpeed : 0
        } else {
            overallCCI = intervalResults.map(\.cci).mean
        }

        let best = intervalResults.min(by: { $0.cci < $1.cci })!
        let worst = intervalResults.max(by: { $0.cci < $1.cci })!

        let pairs = intervalResults.map {
            SPMCCIPair(
                spm: $0.avgSPM,
                cci: $0.cci,
                avgSpeedMPH: $0.avgSpeedMPH,
                source: $0.source,
                isStable: $0.source == "auto"
            )
        }

        let overallAvgSPM = allSPMSamples.isEmpty
            ? 0.0 : allSPMSamples.mean

        return RESummary(
            overallCCI: overallCCI,
            bestIntervalCCI: best.cci,
            worstIntervalCCI: worst.cci,
            bestIntervalNumber: best.intervalNumber,
            worstIntervalNumber: worst.intervalNumber,
            finalTrend: intervalResults.last?.trend ?? .none,
            intervalCount: intervalResults.count,
            spmCCIPairs: pairs,
            overallAvgSPM: overallAvgSPM,
            timeSeries: timeSeriesSamples
        )
    }

    func weightNormalizedCCI(_ rawCCI: Double) -> Double {
        guard baselineWeightLbs > 0 else { return rawCCI }
        return rawCCI * (bodyWeightLbs / baselineWeightLbs)
    }
}

// MARK: - Array Mean Helper

private extension Array where Element == Double {
    var mean: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
