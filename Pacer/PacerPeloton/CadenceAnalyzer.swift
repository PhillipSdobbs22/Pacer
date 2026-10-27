//
//  CadenceAnalyzer.swift
//  PacerPeloton
//
//  Cross-activity SPM bucket analysis with pace-band segmentation.
//  Uses 10-second time-series samples for accurate per-sample
//  pace-band classification: Walking (≤4.2 mph) / Jogging (>4.2 mph).
//  Each stable sample's own speed determines its band, avoiding the
//  averaging problem of 3-minute intervals that blend walk+jog data.
//  Falls back to interval-based analysis for legacy runs without
//  time-series data.  Uses ALL activities — CCI is objective.
//  Within-run delta analysis refines the recommendation when
//  cross-run data is sparse.
//

import Foundation

// MARK: - Pace Band

/// Pace band for segmenting intervals.
enum PaceBand: String, CaseIterable {
    case walking = "Walking"       // ≤ 4.2 mph
    case jogging = "Jogging"       // > 4.2 mph

    /// The speed threshold separating walking from jogging.
    static let threshold: Double = 4.2

    /// Classify a sample or interval by its speed.
    static func classify(_ speedMPH: Double) -> PaceBand {
        speedMPH <= threshold ? .walking : .jogging
    }
}

// MARK: - Result types

/// Confidence in the optimal cadence finding.
enum CadenceConfidence: String {
    case insufficient  = "Need more data"
    case low           = "Early estimate"
    case moderate      = "Moderate confidence"
    case high          = "High confidence"
}

/// A single sample-to-sample or interval-to-interval delta within one run.
struct IntervalDelta {
    let fromSPM: Double
    let toSPM: Double
    let deltaSPM: Double        // toSPM - fromSPM
    let deltaCCI: Double        // toCCI - fromCCI
    let midpointSPM: Double     // average of from/to SPM
    let gradient: Double        // deltaCCI / deltaSPM
}

/// One SPM bucket with its aggregated statistics.
struct CadenceBucket: Identifiable {
    let id: String              // e.g. "170-175"
    let rangeLow: Double
    let rangeHigh: Double
    let avgCCI: Double
    let avgFeeling: Double      // kept for compatibility
    let sampleCount: Int

    // Delta analysis fields
    let avgGradient: Double?    // average ΔCCI/ΔSPM; nil if no delta data
    let deltaCount: Int         // number of qualifying delta pairs
}

/// Analysis result for a single pace band.
struct PaceBandResult {
    let paceBand: PaceBand
    let buckets: [CadenceBucket]            // sorted by rangeLow
    let optimalBucket: CadenceBucket?       // lowest avgCCI (cross-run)
    let confidence: CadenceConfidence
    let totalRuns: Int                      // runs with intervals in this band
    let totalPairsAnalyzed: Int             // SPM-CCI pairs in this band
    let totalDeltaPairs: Int                // qualifying delta pairs
    let deltaOptimalBucket: CadenceBucket?  // optimal from gradient analysis
    let combinedOptimalBucket: CadenceBucket? // merged recommendation
}

/// The full result of a combined cadence analysis.
struct CadenceAnalysisResult {
    // Per-pace-band results
    let walkingResult: PaceBandResult
    let joggingResult: PaceBandResult

    // Legacy compatibility — overall combined (all intervals)
    let buckets: [CadenceBucket]            // sorted by rangeLow
    let optimalBucket: CadenceBucket?       // lowest avgCCI (cross-run)
    let confidence: CadenceConfidence
    let totalGreatRuns: Int                 // now: total runs with RE data
    let totalPairsAnalyzed: Int             // SPM-CCI pairs from all runs
    let totalDeltaPairs: Int                // qualifying delta pairs
    let eligibleRunCount: Int               // runs with deltas
    let deltaOptimalBucket: CadenceBucket?
    let combinedOptimalBucket: CadenceBucket?
}

// MARK: - Analyzer

enum CadenceAnalyzer {

    /// Width of each SPM bucket (e.g. 5 SPM per bucket).
    private static let bucketWidth: Double = 5.0

    /// Minimum SPM change between samples/intervals to count as a meaningful shift.
    private static let minDeltaSPM: Double = 3.0

    /// Skip the first interval of each legacy run — HR lag during warmup
    /// produces artificially low CCI.  Not needed for time-series path
    /// because unstable warmup samples are filtered by isStable.
    private static let warmupIntervalsToSkip = 1

    // MARK: - Main Entry Point

    /// Analyze all runs and return optimal cadence zones per pace band.
    ///
    /// **Primary path** — time-series samples (10 s granularity):
    /// Each stable sample is classified individually by its own speedMPH,
    /// and CCI is computed from that sample's HR and speed.  This avoids
    /// the interval-averaging problem where 3-minute intervals that mix
    /// walking and jogging produce a blended SPM/CCI that belongs to
    /// neither pace band.
    ///
    /// **Legacy fallback** — interval-based SPMCCIPairs:
    /// Runs recorded before time-series collection (timeSeries == nil)
    /// use the original interval-based path with per-interval avgSpeedMPH.
    static func analyze(runs: [RunRecord]) -> CadenceAnalysisResult {

        // ──────────────────────────────────────────────
        // 1. COLLECT SAMPLES (time-series preferred)
        // ──────────────────────────────────────────────

        let runsWithRE = runs.filter { $0.runningEconomy != nil }

        // Separate pairs by pace band
        var walkingPairs: [(spm: Double, cci: Double)] = []
        var joggingPairs: [(spm: Double, cci: Double)] = []
        var allPairs: [(spm: Double, cci: Double)] = []

        // Track which runs contribute to each band
        var walkingRunIDs = Set<UUID>()
        var joggingRunIDs = Set<UUID>()

        for run in runsWithRE {
            guard let re = run.runningEconomy else { continue }

            if let samples = re.timeSeries, !samples.isEmpty {
                // ── TIME-SERIES PATH ──
                // Each 10-second sample is its own data point.
                for sample in samples {
                    // Must be stable, with valid sensor readings
                    guard sample.isStable else { continue }
                    guard sample.spm >= 100 && sample.spm <= 250 else { continue }
                    guard sample.hr > 0 && sample.speedMPH > 0 else { continue }

                    let cci = sample.hr / sample.speedMPH
                    let pair = (spm: sample.spm, cci: cci)

                    allPairs.append(pair)

                    // Classify by this sample's own speed — no averaging
                    let band = PaceBand.classify(sample.speedMPH)
                    switch band {
                    case .walking:
                        walkingPairs.append(pair)
                        walkingRunIDs.insert(run.id)
                    case .jogging:
                        joggingPairs.append(pair)
                        joggingRunIDs.insert(run.id)
                    }
                }
            } else {
                // ── LEGACY FALLBACK (interval-based) ──
                for (index, pair) in re.spmCCIPairs.enumerated() {
                    guard pair.spm >= 100 && pair.spm <= 250 && pair.cci > 0 else { continue }
                    guard pair.isStable ?? true else { continue }
                    guard index >= warmupIntervalsToSkip else { continue }

                    allPairs.append((spm: pair.spm, cci: pair.cci))

                    guard let intervalSpeed = pair.avgSpeedMPH else { continue }
                    let band = PaceBand.classify(intervalSpeed)
                    switch band {
                    case .walking:
                        walkingPairs.append((spm: pair.spm, cci: pair.cci))
                        walkingRunIDs.insert(run.id)
                    case .jogging:
                        joggingPairs.append((spm: pair.spm, cci: pair.cci))
                        joggingRunIDs.insert(run.id)
                    }
                }
            }
        }

        // ──────────────────────────────────────────────
        // 2. DELTA ANALYSIS (all runs, segmented by band)
        // ──────────────────────────────────────────────

        var walkingDeltas: [IntervalDelta] = []
        var joggingDeltas: [IntervalDelta] = []
        var allDeltas: [IntervalDelta] = []

        for run in runsWithRE {
            guard let re = run.runningEconomy else { continue }

            if let samples = re.timeSeries, !samples.isEmpty {
                // Time-series delta extraction
                let segmented = extractDeltasFromTimeSeries(samples: samples)
                walkingDeltas.append(contentsOf: segmented.walking)
                joggingDeltas.append(contentsOf: segmented.jogging)
                allDeltas.append(contentsOf: segmented.walking)
                allDeltas.append(contentsOf: segmented.jogging)
            } else {
                // Legacy interval-based delta extraction
                let segmented = extractDeltasSegmented(from: run)
                walkingDeltas.append(contentsOf: segmented.walking)
                joggingDeltas.append(contentsOf: segmented.jogging)
                allDeltas.append(contentsOf: segmented.walking)
                allDeltas.append(contentsOf: segmented.jogging)
            }
        }

        // ──────────────────────────────────────────────
        // 3. BUILD PER-BAND RESULTS
        // ──────────────────────────────────────────────

        let walkingResult = buildBandResult(
            band: .walking,
            pairs: walkingPairs,
            deltas: walkingDeltas,
            runCount: walkingRunIDs.count
        )

        let joggingResult = buildBandResult(
            band: .jogging,
            pairs: joggingPairs,
            deltas: joggingDeltas,
            runCount: joggingRunIDs.count
        )

        // ──────────────────────────────────────────────
        // 4. LEGACY OVERALL RESULT (for backward compat)
        // ──────────────────────────────────────────────

        let overallResult = buildBandResult(
            band: .jogging,  // placeholder — not used for band label
            pairs: allPairs,
            deltas: allDeltas,
            runCount: runsWithRE.count
        )

        return CadenceAnalysisResult(
            walkingResult: walkingResult,
            joggingResult: joggingResult,
            buckets: overallResult.buckets,
            optimalBucket: overallResult.optimalBucket,
            confidence: overallResult.confidence,
            totalGreatRuns: runsWithRE.count,
            totalPairsAnalyzed: allPairs.count,
            totalDeltaPairs: allDeltas.count,
            eligibleRunCount: runsWithRE.count,
            deltaOptimalBucket: overallResult.deltaOptimalBucket,
            combinedOptimalBucket: overallResult.combinedOptimalBucket
        )
    }

    // MARK: - Build Band Result

    /// Build a complete analysis result for one pace band.
    private static func buildBandResult(
        band: PaceBand,
        pairs: [(spm: Double, cci: Double)],
        deltas: [IntervalDelta],
        runCount: Int
    ) -> PaceBandResult {

        // Determine SPM range
        var allSPMValues: [Double] = pairs.map(\.spm)
        allSPMValues.append(contentsOf: deltas.map(\.midpointSPM))

        guard !allSPMValues.isEmpty else {
            return PaceBandResult(
                paceBand: band,
                buckets: [],
                optimalBucket: nil,
                confidence: .insufficient,
                totalRuns: runCount,
                totalPairsAnalyzed: 0,
                totalDeltaPairs: 0,
                deltaOptimalBucket: nil,
                combinedOptimalBucket: nil
            )
        }

        let minSPM = allSPMValues.min()!
        let maxSPM = allSPMValues.max()!
        let bucketFloor = floor(minSPM / bucketWidth) * bucketWidth
        let bucketCeiling = ceil(maxSPM / bucketWidth) * bucketWidth

        var buckets: [CadenceBucket] = []
        var low = bucketFloor
        while low < bucketCeiling {
            let high = low + bucketWidth

            let pairsInBucket = pairs.filter { $0.spm >= low && $0.spm < high }
            let avgCCI: Double = pairsInBucket.isEmpty
                ? 0
                : pairsInBucket.map(\.cci).reduce(0, +) / Double(pairsInBucket.count)

            let deltasInBucket = deltas.filter { $0.midpointSPM >= low && $0.midpointSPM < high }
            let avgGradient: Double? = deltasInBucket.isEmpty
                ? nil
                : deltasInBucket.map(\.gradient).reduce(0, +) / Double(deltasInBucket.count)

            if !pairsInBucket.isEmpty || !deltasInBucket.isEmpty {
                buckets.append(CadenceBucket(
                    id: "\(Int(low))-\(Int(high))",
                    rangeLow: low,
                    rangeHigh: high,
                    avgCCI: avgCCI,
                    avgFeeling: 0,
                    sampleCount: pairsInBucket.count,
                    avgGradient: avgGradient,
                    deltaCount: deltasInBucket.count
                ))
            }

            low = high
        }

        let sortedBuckets = buckets.sorted { $0.rangeLow < $1.rangeLow }

        // Cross-run optimal: lowest avgCCI among buckets with ≥ 3 samples
        let crossRunOptimal = sortedBuckets
            .filter { $0.sampleCount >= 3 }
            .min(by: { $0.avgCCI < $1.avgCCI })

        // Delta optimal: closest gradient to zero with ≥ 3 delta pairs
        let deltaOptimal = sortedBuckets
            .filter { $0.deltaCount >= 3 && $0.avgGradient != nil }
            .min(by: { abs($0.avgGradient!) < abs($1.avgGradient!) })

        let combinedOptimal = determineCombinedOptimal(
            crossRunOptimal: crossRunOptimal,
            deltaOptimal: deltaOptimal,
            runCount: runCount,
            totalDeltas: deltas.count,
            buckets: sortedBuckets
        )

        let confidence = determineConfidence(
            runCount: runCount,
            deltaCount: deltas.count
        )

        return PaceBandResult(
            paceBand: band,
            buckets: sortedBuckets,
            optimalBucket: crossRunOptimal,
            confidence: confidence,
            totalRuns: runCount,
            totalPairsAnalyzed: pairs.count,
            totalDeltaPairs: deltas.count,
            deltaOptimalBucket: deltaOptimal,
            combinedOptimalBucket: combinedOptimal
        )
    }

    // MARK: - Delta Extraction (Time-Series)

    /// Extract deltas from time-series samples, segmented by pace band.
    ///
    /// Walks through stable samples and forms delta pairs between
    /// consecutive samples *within the same pace band* where the SPM
    /// shift is ≥ minDeltaSPM.  Because each sample has its own speed,
    /// a walk→jog transition simply resets the "previous" anchor for
    /// each band — no cross-band deltas are produced.
    private static func extractDeltasFromTimeSeries(
        samples: [TimeSeriesSampleRecord]
    ) -> (walking: [IntervalDelta], jogging: [IntervalDelta]) {

        var walkingDeltas: [IntervalDelta] = []
        var joggingDeltas: [IntervalDelta] = []

        // Track last stable sample seen in each band
        var lastWalking: (spm: Double, cci: Double)?
        var lastJogging: (spm: Double, cci: Double)?

        for sample in samples {
            guard sample.isStable else {
                // Unstable sample breaks continuity in both bands
                lastWalking = nil
                lastJogging = nil
                continue
            }
            guard sample.spm >= 100 && sample.spm <= 250 else { continue }
            guard sample.hr > 0 && sample.speedMPH > 0 else { continue }

            let cci = sample.hr / sample.speedMPH
            let current = (spm: sample.spm, cci: cci)
            let band = PaceBand.classify(sample.speedMPH)

            switch band {
            case .walking:
                if let prev = lastWalking {
                    let deltaSPM = current.spm - prev.spm
                    if abs(deltaSPM) >= minDeltaSPM {
                        let deltaCCI = current.cci - prev.cci
                        walkingDeltas.append(IntervalDelta(
                            fromSPM: prev.spm,
                            toSPM: current.spm,
                            deltaSPM: deltaSPM,
                            deltaCCI: deltaCCI,
                            midpointSPM: (prev.spm + current.spm) / 2.0,
                            gradient: deltaCCI / deltaSPM
                        ))
                    }
                }
                lastWalking = current
                // Switching to walking resets jogging continuity
                lastJogging = nil

            case .jogging:
                if let prev = lastJogging {
                    let deltaSPM = current.spm - prev.spm
                    if abs(deltaSPM) >= minDeltaSPM {
                        let deltaCCI = current.cci - prev.cci
                        joggingDeltas.append(IntervalDelta(
                            fromSPM: prev.spm,
                            toSPM: current.spm,
                            deltaSPM: deltaSPM,
                            deltaCCI: deltaCCI,
                            midpointSPM: (prev.spm + current.spm) / 2.0,
                            gradient: deltaCCI / deltaSPM
                        ))
                    }
                }
                lastJogging = current
                // Switching to jogging resets walking continuity
                lastWalking = nil
            }
        }

        return (walking: walkingDeltas, jogging: joggingDeltas)
    }

    // MARK: - Delta Extraction (Segmented — Legacy)

    /// Extract deltas from a run using interval-based SPMCCIPairs.
    /// Used as fallback for runs without time-series data.
    /// Skips deltas involving warmup intervals (HR lag artifacts).
    private static func extractDeltasSegmented(
        from run: RunRecord
    ) -> (walking: [IntervalDelta], jogging: [IntervalDelta]) {
        guard let re = run.runningEconomy else { return ([], []) }
        let pairs = re.spmCCIPairs
        guard pairs.count >= 2 else { return ([], []) }

        var walkingDeltas: [IntervalDelta] = []
        var joggingDeltas: [IntervalDelta] = []

        // Start after warmup intervals so neither endpoint is a warmup artifact
        let startIndex = warmupIntervalsToSkip
        guard startIndex < pairs.count - 1 else { return ([], []) }

        for i in startIndex..<(pairs.count - 1) {
            let from = pairs[i]
            let to = pairs[i + 1]

            guard from.spm >= 100 && from.spm <= 250 && from.cci > 0,
                  to.spm >= 100 && to.spm <= 250 && to.cci > 0 else {
                continue
            }

            let deltaSPM = to.spm - from.spm
            guard abs(deltaSPM) >= minDeltaSPM else { continue }

            let deltaCCI = to.cci - from.cci
            let midpoint = (from.spm + to.spm) / 2.0
            let gradient = deltaCCI / deltaSPM

            let delta = IntervalDelta(
                fromSPM: from.spm,
                toSPM: to.spm,
                deltaSPM: deltaSPM,
                deltaCCI: deltaCCI,
                midpointSPM: midpoint,
                gradient: gradient
            )

            // Classify delta by per-interval speed of both intervals.
            // If either interval lacks its own speed, skip band classification
            // to prevent run-level fallback from misclassifying the delta.
            guard let fromSpeed = from.avgSpeedMPH,
                  let toSpeed = to.avgSpeedMPH else {
                continue
            }
            let avgSpeed = (fromSpeed + toSpeed) / 2.0
            let band = PaceBand.classify(avgSpeed)

            switch band {
            case .walking: walkingDeltas.append(delta)
            case .jogging: joggingDeltas.append(delta)
            }
        }

        return (walking: walkingDeltas, jogging: joggingDeltas)
    }

    // MARK: - Combined Optimal

    private static func determineCombinedOptimal(
        crossRunOptimal: CadenceBucket?,
        deltaOptimal: CadenceBucket?,
        runCount: Int,
        totalDeltas: Int,
        buckets: [CadenceBucket]
    ) -> CadenceBucket? {

        guard crossRunOptimal != nil || deltaOptimal != nil else {
            return nil
        }

        if crossRunOptimal == nil { return deltaOptimal }
        if deltaOptimal == nil { return crossRunOptimal }

        let crossRun = crossRunOptimal!
        let delta = deltaOptimal!

        if crossRun.id == delta.id {
            return crossRun
        }

        // Priority based on data volume
        if runCount >= 10 {
            return crossRun
        } else if runCount >= 5 {
            return crossRun.sampleCount >= delta.deltaCount ? crossRun : delta
        } else {
            if totalDeltas >= 5 {
                return delta
            } else {
                return crossRun.sampleCount >= delta.deltaCount ? crossRun : delta
            }
        }
    }

    // MARK: - Confidence

    private static func determineConfidence(
        runCount: Int,
        deltaCount: Int
    ) -> CadenceConfidence {
        if runCount >= 10 && deltaCount >= 20 {
            return .high
        }
        if runCount >= 5 || (runCount >= 3 && deltaCount >= 15) {
            return .moderate
        }
        if runCount >= 3 || deltaCount >= 5 {
            return .low
        }
        return .insufficient
    }
}
