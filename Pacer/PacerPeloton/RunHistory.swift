//
//  RunHistory.swift
//  PacerPeloton
//
//  Model and store for running activity records received from
//  the Watch Pacer app. Persists as JSON in the iPhone's
//  Documents directory.
//

import Foundation
import Combine

/// A single SPM-CCI pair from one 3-minute interval.
struct SPMCCIPairRecord: Codable {
    let spm: Double
    let cci: Double
}

/// Running Economy data embedded in a run record.
struct RunREData: Codable {
    let overallCCI: Double
    let bestIntervalCCI: Double
    let bestIntervalNumber: Int
    let worstIntervalCCI: Double
    let worstIntervalNumber: Int
    let trend: String
    let intervalCount: Int
    let overallAvgSPM: Double
    let spmCCIPairs: [SPMCCIPairRecord]
}

/// A completed run received from the Watch Pacer app.
struct RunRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let elapsedSeconds: TimeInterval
    let elapsedFormatted: String
    let distanceMiles: Double
    let paceSecondsPerMile: Double
    let paceFormatted: String
    let avgSpeedMPH: Double
    let heartRateZone: Int
    let avgStepsPerMin: Double
    let totalSteps: Int
    let activeCalories: Double
    let maxHR: Double
    let goalPaceMPH: Double
    let feelingRating: Int          // 1=BAD, 2=NOT BAD, 3=GREAT
    let runningEconomy: RunREData?
    let weightNormalizedCCI: Double?
}

/// Persists run records as JSON in the app's Documents directory.
@MainActor
final class RunStore: ObservableObject {
    static let shared = RunStore()

    @Published private(set) var runs: [RunRecord] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("run_history.json")
    }()

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            runs = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(
            [RunRecord].self, from: data) else {
            runs = []
            return
        }
        runs = decoded.sorted { $0.date > $1.date }
    }

    func save(_ record: RunRecord) {
        // Prevent duplicates (same date within 1 second)
        let dominated = runs.contains { existing in
            abs(existing.date.timeIntervalSince(record.date)) < 1.0
        }
        guard !dominated else {
            print("[RunStore] Duplicate run ignored: \(record.date)")
            return
        }

        runs.insert(record, at: 0)
        runs.sort { $0.date > $1.date }
        persist()
    }

    func delete(_ id: UUID) {
        runs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(runs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Parse from Watch userInfo dictionary

    /// Creates a RunRecord from the raw dictionary sent by the Watch.
    static func record(from info: [String: Any]) -> RunRecord? {
        guard let dateString = info["date"] as? String,
              let date = ISO8601DateFormatter().date(from: dateString) else {
            print("[RunStore] Missing or invalid date")
            return nil
        }

        let elapsedSeconds = info["elapsedSeconds"] as? Double ?? 0
        let elapsedFormatted = info["elapsedFormatted"] as? String ?? "0:00:00"
        let distanceMiles = info["distanceMiles"] as? Double ?? 0
        let paceSecondsPerMile = info["paceSecondsPerMile"] as? Double ?? 0
        let paceFormatted = info["paceFormatted"] as? String ?? "N/A"
        let avgSpeedMPH = info["avgSpeedMPH"] as? Double ?? 0
        let heartRateZone = info["heartRateZone"] as? Int ?? 0
        let avgStepsPerMin = info["avgStepsPerMin"] as? Double ?? 0
        let totalSteps = info["totalSteps"] as? Int ?? 0
        let activeCalories = info["activeCalories"] as? Double ?? 0
        let maxHR = info["maxHR"] as? Double ?? 0
        let goalPaceMPH = info["goalPaceMPH"] as? Double ?? 0
        let feelingRating = info["feelingRating"] as? Int ?? 0

        // Parse running economy data if present
        var reData: RunREData?
        if let reDict = info["runningEconomy"] as? [String: Any] {
            let overallCCI = reDict["overallCCI"] as? Double ?? 0
            let bestCCI = reDict["bestIntervalCCI"] as? Double ?? 0
            let bestNum = reDict["bestIntervalNumber"] as? Int ?? 0
            let worstCCI = reDict["worstIntervalCCI"] as? Double ?? 0
            let worstNum = reDict["worstIntervalNumber"] as? Int ?? 0
            let trend = reDict["trend"] as? String ?? ""
            let intervalCount = reDict["intervalCount"] as? Int ?? 0
            let overallAvgSPM = reDict["overallAvgSPM"] as? Double ?? 0

            var pairs: [SPMCCIPairRecord] = []
            if let rawPairs = reDict["spmCCIPairs"] as? [[String: Any]] {
                pairs = rawPairs.compactMap { dict in
                    guard let spm = dict["spm"] as? Double,
                          let cci = dict["cci"] as? Double else { return nil }
                    return SPMCCIPairRecord(spm: spm, cci: cci)
                }
            }

            reData = RunREData(
                overallCCI: overallCCI,
                bestIntervalCCI: bestCCI,
                bestIntervalNumber: bestNum,
                worstIntervalCCI: worstCCI,
                worstIntervalNumber: worstNum,
                trend: trend,
                intervalCount: intervalCount,
                overallAvgSPM: overallAvgSPM,
                spmCCIPairs: pairs
            )
        }

        let weightNormCCI = info["weightNormalizedCCI"] as? Double

        return RunRecord(
            id: UUID(),
            date: date,
            elapsedSeconds: elapsedSeconds,
            elapsedFormatted: elapsedFormatted,
            distanceMiles: distanceMiles,
            paceSecondsPerMile: paceSecondsPerMile,
            paceFormatted: paceFormatted,
            avgSpeedMPH: avgSpeedMPH,
            heartRateZone: heartRateZone,
            avgStepsPerMin: avgStepsPerMin,
            totalSteps: totalSteps,
            activeCalories: activeCalories,
            maxHR: maxHR,
            goalPaceMPH: goalPaceMPH,
            feelingRating: feelingRating,
            runningEconomy: reData,
            weightNormalizedCCI: weightNormCCI
        )
    }
}
