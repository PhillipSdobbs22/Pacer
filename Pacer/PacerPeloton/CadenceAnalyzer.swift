//
//  CadenceAnalyzer.swift
//  PacerPeloton
//
//  Cross-activity SPM bucket analysis with pace-band segmentation.
//  Splits intervals into Walking (≤4 mph) and Jogging (>4 mph)
//  pace bands, then finds the optimal SPM for lowest CCI in each.
//  Uses ALL activities (no rating filter) — CCI is objective.
//  Within-run delta analysis refines the recommendation when
//  cross-run data is sparse.
//

import Foundation

// MARK: - Pace Band

/// Pace band for segmenting intervals.
enum PaceBand: String, CaseIterable {
    case walking = "Walking"       // ≤ 4.0 mph
    case jogging = "Jogging"       // > 4.0 mph

    /// The speed threshold separating walking from jogging.
    static let threshold: Double = 4.0

    /// Classify an interval by its average speed.
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

/// A single interval-to-interval delta within one run.
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

    /// Minimum SPM change between intervals to count as a meaningful shift.
    private static let minDeltaSPM: Double = 3.0

    /// Analyze all runs and return optimal cadence zones per pace band.
    static func analyze(runs: [RunRecord]) -> CadenceAnalysisResult {

        // ──────────────────────────────────────────────
        // 1. COLLECT ALL INTERVALS (no rating filter)
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
            for pair in re.spmCCIPairs {
                guard pair.spm >= 100 && pair.spm <= 250 && pair.cci > 0 else { continue }
                // Prefer stable pairs; include legacy data (isStable == nil) for backward compat
                guard pair.isStable ?? true else { continue }
                allPairs.append((spm: pair.spm, cci: pair.cci))

                // Classify by speed if available; fall back to run-level avg
                let speed = pair.avgSpeedMPH ?? run.avgSpeedMPH
                let band = PaceBand.classify(speed)

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

        // ──────────────────────────────────────────────
        // 2. DELTA ANALYSIS (all runs, segmented by band)
        // ──────────────────────────────────────────────

        var walkingDeltas: [IntervalDelta] = []
        var joggingDeltas: [IntervalDelta] = []
        var allDeltas: [IntervalDelta] = []

        for run in runsWithRE {
            let segmented = extractDeltasSegmented(from: run)
            walkingDeltas.append(contentsOf: segmented.walking)
            joggingDeltas.append(contentsOf: segmented.jogging)
            allDeltas.append(contentsOf: segmented.walking)
            allDeltas.append(contentsOf: segmented.jogging)
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

    // MARK: - Delta Extraction (Segmented)

    /// Extract deltas from a run, segmented into walking and jogging bands.
    private static func extractDeltasSegmented(
        from run: RunRecord
    ) -> (walking: [IntervalDelta], jogging: [IntervalDelta]) {
        guard let re = run.runningEconomy else { return ([], []) }
        let pairs = re.spmCCIPairs
        guard pairs.count >= 2 else { return ([], []) }

        var walkingDeltas: [IntervalDelta] = []
        var joggingDeltas: [IntervalDelta] = []

        for i in 0..<(pairs.count - 1) {
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

            // Classify delta by the average speed of both intervals
            let fromSpeed = from.avgSpeedMPH ?? run.avgSpeedMPH
            let toSpeed = to.avgSpeedMPH ?? run.avgSpeedMPH
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
