//
//  CadenceAnalyzer.swift
//  PacerPeloton
//
//  Cross-activity SPM bucket analysis with within-run delta analysis.
//  Filters to GREAT-rated runs for absolute CCI buckets, and
//  GREAT + NOT BAD runs for interval-to-interval delta gradients.
//  Merges both signals to identify the optimal cadence zone faster.
//

import Foundation

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
    let avgFeeling: Double      // always 3.0 for GREAT-only cross-run
    let sampleCount: Int

    // Delta analysis fields
    let avgGradient: Double?    // average ΔCCI/ΔSPM; nil if no delta data
    let deltaCount: Int         // number of qualifying delta pairs
}

/// The full result of a combined cadence analysis.
struct CadenceAnalysisResult {
    // Cross-run analysis (existing)
    let buckets: [CadenceBucket]            // sorted by rangeLow
    let optimalBucket: CadenceBucket?       // lowest avgCCI (cross-run)
    let confidence: CadenceConfidence
    let totalGreatRuns: Int                 // GREAT-rated runs with RE data
    let totalPairsAnalyzed: Int             // SPM-CCI pairs from GREAT runs

    // Delta analysis (new)
    let totalDeltaPairs: Int                // qualifying delta pairs across all eligible runs
    let eligibleRunCount: Int               // GREAT + NOT BAD runs with deltas
    let deltaOptimalBucket: CadenceBucket?  // optimal from gradient analysis alone
    let combinedOptimalBucket: CadenceBucket? // merged recommendation
}

// MARK: - Analyzer

enum CadenceAnalyzer {

    /// Width of each SPM bucket (e.g. 5 SPM per bucket).
    private static let bucketWidth: Double = 5.0

    /// Minimum SPM change between intervals to count as a meaningful shift.
    private static let minDeltaSPM: Double = 3.0

    /// Analyze all runs in the store and return the optimal cadence zone.
    static func analyze(runs: [RunRecord]) -> CadenceAnalysisResult {

        // ──────────────────────────────────────────────
        // 1. CROSS-RUN ANALYSIS (GREAT runs only)
        // ──────────────────────────────────────────────

        let greatRuns = runs.filter { $0.feelingRating == 3 && $0.runningEconomy != nil }

        var allPairs: [(spm: Double, cci: Double)] = []
        for run in greatRuns {
            guard let re = run.runningEconomy else { continue }
            for pair in re.spmCCIPairs {
                if pair.spm >= 100 && pair.spm <= 250 && pair.cci > 0 {
                    allPairs.append((spm: pair.spm, cci: pair.cci))
                }
            }
        }

        // ──────────────────────────────────────────────
        // 2. DELTA ANALYSIS (GREAT + NOT BAD runs)
        // ──────────────────────────────────────────────

        let eligibleRuns = runs.filter {
            $0.feelingRating >= 2 && $0.runningEconomy != nil
        }

        var allDeltas: [IntervalDelta] = []
        for run in eligibleRuns {
            let deltas = extractDeltas(from: run)
            allDeltas.append(contentsOf: deltas)
        }

        // ──────────────────────────────────────────────
        // 3. BUILD UNIFIED BUCKETS
        // ──────────────────────────────────────────────

        // Determine global SPM range from both data sources
        var allSPMValues: [Double] = allPairs.map(\.spm)
        allSPMValues.append(contentsOf: allDeltas.map(\.midpointSPM))

        guard !allSPMValues.isEmpty else {
            return CadenceAnalysisResult(
                buckets: [],
                optimalBucket: nil,
                confidence: .insufficient,
                totalGreatRuns: greatRuns.count,
                totalPairsAnalyzed: 0,
                totalDeltaPairs: 0,
                eligibleRunCount: eligibleRuns.count,
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

            // Cross-run pairs in this bucket
            let pairsInBucket = allPairs.filter { $0.spm >= low && $0.spm < high }
            let avgCCI: Double
            if pairsInBucket.isEmpty {
                avgCCI = 0
            } else {
                avgCCI = pairsInBucket.map(\.cci).reduce(0, +) / Double(pairsInBucket.count)
            }

            // Delta pairs in this bucket (by midpointSPM)
            let deltasInBucket = allDeltas.filter { $0.midpointSPM >= low && $0.midpointSPM < high }
            let avgGradient: Double?
            if deltasInBucket.isEmpty {
                avgGradient = nil
            } else {
                avgGradient = deltasInBucket.map(\.gradient).reduce(0, +) / Double(deltasInBucket.count)
            }

            // Only create bucket if it has any data
            if !pairsInBucket.isEmpty || !deltasInBucket.isEmpty {
                buckets.append(CadenceBucket(
                    id: "\(Int(low))-\(Int(high))",
                    rangeLow: low,
                    rangeHigh: high,
                    avgCCI: avgCCI,
                    avgFeeling: 3.0,
                    sampleCount: pairsInBucket.count,
                    avgGradient: avgGradient,
                    deltaCount: deltasInBucket.count
                ))
            }

            low = high
        }

        let sortedBuckets = buckets.sorted { $0.rangeLow < $1.rangeLow }

        // ──────────────────────────────────────────────
        // 4. FIND OPTIMAL BUCKETS
        // ──────────────────────────────────────────────

        // Cross-run optimal: lowest avgCCI among buckets with ≥ 3 samples
        let crossRunOptimal = sortedBuckets
            .filter { $0.sampleCount >= 3 }
            .min(by: { $0.avgCCI < $1.avgCCI })

        // Delta optimal: bucket where gradient is closest to zero (with ≥ 3 delta pairs)
        let deltaOptimal = sortedBuckets
            .filter { $0.deltaCount >= 3 && $0.avgGradient != nil }
            .min(by: { abs($0.avgGradient!) < abs($1.avgGradient!) })

        // Combined optimal: merge both signals based on data availability
        let combinedOptimal = determineCombinedOptimal(
            crossRunOptimal: crossRunOptimal,
            deltaOptimal: deltaOptimal,
            greatRunCount: greatRuns.count,
            totalDeltas: allDeltas.count,
            buckets: sortedBuckets
        )

        // ──────────────────────────────────────────────
        // 5. CONFIDENCE TIER
        // ──────────────────────────────────────────────

        let confidence = determineConfidence(
            greatRunCount: greatRuns.count,
            deltaCount: allDeltas.count
        )

        return CadenceAnalysisResult(
            buckets: sortedBuckets,
            optimalBucket: crossRunOptimal,
            confidence: confidence,
            totalGreatRuns: greatRuns.count,
            totalPairsAnalyzed: allPairs.count,
            totalDeltaPairs: allDeltas.count,
            eligibleRunCount: eligibleRuns.count,
            deltaOptimalBucket: deltaOptimal,
            combinedOptimalBucket: combinedOptimal
        )
    }

    // MARK: - Delta Extraction

    /// Extract qualifying interval-to-interval deltas from a single run.
    private static func extractDeltas(from run: RunRecord) -> [IntervalDelta] {
        guard let re = run.runningEconomy else { return [] }
        let pairs = re.spmCCIPairs

        // Need at least 2 intervals
        guard pairs.count >= 2 else { return [] }

        var deltas: [IntervalDelta] = []

        for i in 0..<(pairs.count - 1) {
            let from = pairs[i]
            let to = pairs[i + 1]

            // Sanity checks
            guard from.spm >= 100 && from.spm <= 250 && from.cci > 0,
                  to.spm >= 100 && to.spm <= 250 && to.cci > 0 else {
                continue
            }

            let deltaSPM = to.spm - from.spm

            // Filter: only meaningful cadence shifts
            guard abs(deltaSPM) >= minDeltaSPM else { continue }

            let deltaCCI = to.cci - from.cci
            let midpoint = (from.spm + to.spm) / 2.0
            let gradient = deltaCCI / deltaSPM

            deltas.append(IntervalDelta(
                fromSPM: from.spm,
                toSPM: to.spm,
                deltaSPM: deltaSPM,
                deltaCCI: deltaCCI,
                midpointSPM: midpoint,
                gradient: gradient
            ))
        }

        return deltas
    }

    // MARK: - Combined Optimal

    /// Merge cross-run and delta signals to pick the best combined recommendation.
    private static func determineCombinedOptimal(
        crossRunOptimal: CadenceBucket?,
        deltaOptimal: CadenceBucket?,
        greatRunCount: Int,
        totalDeltas: Int,
        buckets: [CadenceBucket]
    ) -> CadenceBucket? {

        // Both nil → no recommendation
        guard crossRunOptimal != nil || deltaOptimal != nil else {
            return nil
        }

        // Only one signal available → use it
        if crossRunOptimal == nil { return deltaOptimal }
        if deltaOptimal == nil { return crossRunOptimal }

        // Both available — weight depends on data volume
        let crossRun = crossRunOptimal!
        let delta = deltaOptimal!

        // If they agree (same bucket), that's the answer
        if crossRun.id == delta.id {
            return crossRun
        }

        // Priority logic based on data maturity
        if greatRunCount >= 10 {
            // Cross-run has high confidence — it leads, delta refines
            return crossRun
        } else if greatRunCount >= 5 {
            // Moderate cross-run data — pick the one with more evidence
            // Score: cross-run by sample count, delta by delta count
            if crossRun.sampleCount >= delta.deltaCount {
                return crossRun
            } else {
                return delta
            }
        } else {
            // Sparse cross-run data — delta leads
            if totalDeltas >= 5 {
                return delta
            } else {
                // Both sparse — return whichever has more data points
                return crossRun.sampleCount >= delta.deltaCount ? crossRun : delta
            }
        }
    }

    // MARK: - Confidence

    /// Determine confidence tier from both data sources.
    private static func determineConfidence(
        greatRunCount: Int,
        deltaCount: Int
    ) -> CadenceConfidence {
        // High: 10+ GREAT runs AND 20+ delta pairs
        if greatRunCount >= 10 && deltaCount >= 20 {
            return .high
        }
        // Moderate: 5-10 GREAT runs, OR any GREAT runs + 15-30 deltas
        if greatRunCount >= 5 || (greatRunCount >= 3 && deltaCount >= 15) {
            return .moderate
        }
        // Low: 3-5 GREAT runs OR 5-15 delta pairs
        if greatRunCount >= 3 || deltaCount >= 5 {
            return .low
        }
        // Insufficient
        return .insufficient
    }
}
