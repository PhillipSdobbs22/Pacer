//
//  CadenceAnalyzer.swift
//  PacerPeloton
//
//  Cross-activity SPM bucket analysis.
//  Filters to GREAT-rated runs, buckets SPM-CCI pairs,
//  and identifies the optimal cadence zone with confidence tiers.
//

import Foundation

// MARK: - Result types

/// Confidence in the optimal cadence finding.
enum CadenceConfidence: String {
    case insufficient  = "Need more data"
    case low           = "Low confidence"
    case moderate      = "Moderate confidence"
    case high          = "High confidence"
}

/// One SPM bucket with its aggregated statistics.
struct CadenceBucket: Identifiable {
    let id: String          // e.g. "170-175"
    let rangeLow: Double
    let rangeHigh: Double
    let avgCCI: Double
    let avgFeeling: Double  // always 3.0 for GREAT-only filter
    let sampleCount: Int
}

/// The full result of a cross-activity cadence analysis.
struct CadenceAnalysisResult {
    let buckets: [CadenceBucket]           // sorted by rangeLow
    let optimalBucket: CadenceBucket?      // lowest avgCCI
    let confidence: CadenceConfidence
    let totalGreatRuns: Int                // GREAT-rated runs with RE data
    let totalPairsAnalyzed: Int            // SPM-CCI pairs used
}

// MARK: - Analyzer

enum CadenceAnalyzer {

    /// Width of each SPM bucket (e.g. 5 SPM per bucket).
    private static let bucketWidth: Double = 5.0

    /// Analyze all runs in the store and return the optimal cadence zone.
    static func analyze(runs: [RunRecord]) -> CadenceAnalysisResult {

        // 1. Filter to GREAT-rated runs (feelingRating == 3) that have RE data
        let greatRuns = runs.filter { $0.feelingRating == 3 && $0.runningEconomy != nil }

        // 2. Collect all SPM-CCI pairs from those runs
        var allPairs: [(spm: Double, cci: Double)] = []
        for run in greatRuns {
            guard let re = run.runningEconomy else { continue }
            for pair in re.spmCCIPairs {
                // Sanity: only include reasonable SPM values
                if pair.spm >= 100 && pair.spm <= 250 && pair.cci > 0 {
                    allPairs.append((spm: pair.spm, cci: pair.cci))
                }
            }
        }

        // 3. If no pairs, return empty result
        guard !allPairs.isEmpty else {
            return CadenceAnalysisResult(
                buckets: [],
                optimalBucket: nil,
                confidence: .insufficient,
                totalGreatRuns: greatRuns.count,
                totalPairsAnalyzed: 0
            )
        }

        // 4. Determine bucket boundaries from data range
        let minSPM = allPairs.map(\.spm).min()!
        let bucketFloor = floor(minSPM / bucketWidth) * bucketWidth

        let maxSPM = allPairs.map(\.spm).max()!
        let bucketCeiling = ceil(maxSPM / bucketWidth) * bucketWidth

        // 5. Build buckets
        var buckets: [CadenceBucket] = []
        var low = bucketFloor
        while low < bucketCeiling {
            let high = low + bucketWidth
            let inBucket = allPairs.filter { $0.spm >= low && $0.spm < high }
            if !inBucket.isEmpty {
                let avgCCI = inBucket.map(\.cci).reduce(0, +) / Double(inBucket.count)
                buckets.append(CadenceBucket(
                    id: "\(Int(low))-\(Int(high))",
                    rangeLow: low,
                    rangeHigh: high,
                    avgCCI: avgCCI,
                    avgFeeling: 3.0,    // GREAT-only filter
                    sampleCount: inBucket.count
                ))
            }
            low = high
        }

        // 6. Find optimal bucket (lowest avgCCI)
        let optimal = buckets.min(by: { $0.avgCCI < $1.avgCCI })

        // 7. Confidence tier based on GREAT-run count
        let confidence: CadenceConfidence
        switch greatRuns.count {
        case 0..<5:   confidence = .insufficient
        case 5...10:  confidence = .low
        case 11...20: confidence = .moderate
        default:      confidence = .high
        }

        return CadenceAnalysisResult(
            buckets: buckets.sorted(by: { $0.rangeLow < $1.rangeLow }),
            optimalBucket: optimal,
            confidence: confidence,
            totalGreatRuns: greatRuns.count,
            totalPairsAnalyzed: allPairs.count
        )
    }
}
