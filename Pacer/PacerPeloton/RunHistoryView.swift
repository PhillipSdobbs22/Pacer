//
//  RunHistoryView.swift
//  PacerPeloton
//
//  Displays a scrollable list of past running activities received
//  from the Watch Pacer app. Each row shows key stats at a glance:
//  Date, Feeling, CCI, SPM, Elapsed, HR Zone, Speed, Distance, Pace.
//  A header card shows the combined optimal cadence zone
//  (cross-run buckets + within-run delta analysis).
//  Each row has a share button to export as GPX for Strava/Garmin/etc.
//

import SwiftUI

// MARK: - Run History Tab

struct RunHistoryTab: View {
    @ObservedObject var runStore: RunStore

    private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

    /// Computed analysis result — recalculates when runs change.
    private var analysis: CadenceAnalysisResult {
        CadenceAnalyzer.analyze(runs: runStore.runs)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                navy.ignoresSafeArea()
                Group {
                    if runStore.runs.isEmpty {
                        emptyState
                    } else {
                        runList
                    }
                }
            }
            .navigationTitle("Runs")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.system(size: 48))
                .foregroundStyle(yellow)
            Text("No runs yet")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Complete a run on your Watch\nto see your history here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding()
    }

    // MARK: - Run List

    private var runList: some View {
        List {
            // Optimal Cadence Zone header card
            OptimalCadenceCard(analysis: analysis)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            ForEach(runStore.runs) { run in
                RunHistoryRow(run: run)
                    .listRowBackground(Color(white: 0.12))
            }
            .onDelete(perform: deleteRun)
        }
        .scrollContentBackground(.hidden)
    }

    private func deleteRun(at offsets: IndexSet) {
        for index in offsets {
            let run = runStore.runs[index]
            runStore.delete(run.id)
        }
    }
}

// MARK: - Optimal Cadence Card

struct OptimalCadenceCard: View {
    let analysis: CadenceAnalysisResult

    private let cyan = Color.cyan
    private let cardBG = Color(white: 0.10)

    /// The best recommendation: combined if available, else cross-run, else delta.
    private var displayBucket: CadenceBucket? {
        analysis.combinedOptimalBucket ?? analysis.optimalBucket ?? analysis.deltaOptimalBucket
    }

    /// Label describing which signal is driving the recommendation.
    private var signalLabel: String {
        if analysis.combinedOptimalBucket != nil {
            if analysis.optimalBucket != nil && analysis.deltaOptimalBucket != nil {
                return "Cross-run + Delta"
            } else if analysis.deltaOptimalBucket != nil {
                return "Delta analysis"
            } else {
                return "Cross-run"
            }
        } else if analysis.optimalBucket != nil {
            return "Cross-run"
        } else if analysis.deltaOptimalBucket != nil {
            return "Delta analysis"
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 8) {
            // Title row
            HStack {
                Image(systemName: "metronome.fill")
                    .foregroundStyle(cyan)
                Text("Optimal Cadence Zone")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
            }

            if let optimal = displayBucket {
                // Big cadence range
                Text("\(Int(optimal.rangeLow))–\(Int(optimal.rangeHigh)) SPM")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(cyan)

                // Detail line: CCI and/or gradient
                detailLine(for: optimal)

                // Confidence badge + signal source
                HStack(spacing: 8) {
                    confidenceBadge
                    if !signalLabel.isEmpty {
                        Text(signalLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            } else {
                // Not enough data yet
                Text("—")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Complete more runs to find your optimal cadence.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            // Stats line — now includes delta metrics
            HStack(spacing: 12) {
                miniStat(label: "GREAT runs", value: "\(analysis.totalGreatRuns)")
                miniStat(label: "Intervals", value: "\(analysis.totalPairsAnalyzed)")
                miniStat(label: "Deltas", value: "\(analysis.totalDeltaPairs)")
                miniStat(label: "Eligible", value: "\(analysis.eligibleRunCount)")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(cyan.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Detail Line

    @ViewBuilder
    private func detailLine(for bucket: CadenceBucket) -> some View {
        if bucket.sampleCount > 0 && bucket.avgCCI > 0 {
            // Has cross-run CCI data
            if let gradient = bucket.avgGradient {
                Text(String(format: "Avg CCI: %.1f  ·  %d intervals  ·  slope: %+.2f",
                            bucket.avgCCI, bucket.sampleCount, gradient))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text(String(format: "Avg CCI: %.1f  ·  %d intervals",
                            bucket.avgCCI, bucket.sampleCount))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else if let gradient = bucket.avgGradient {
            // Delta-only bucket (no cross-run data yet)
            Text(String(format: "Slope: %+.2f  ·  %d delta pairs",
                        gradient, bucket.deltaCount))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Confidence Badge

    private var confidenceBadge: some View {
        let (text, color) = confidenceDisplay(analysis.confidence)
        return Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
    }

    private func confidenceDisplay(_ level: CadenceConfidence) -> (String, Color) {
        switch level {
        case .insufficient: return (level.rawValue, .gray)
        case .low:          return (level.rawValue, .orange)
        case .moderate:     return (level.rawValue, .yellow)
        case .high:         return (level.rawValue, .green)
        }
    }

    // MARK: - Mini Stat

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Row

struct RunHistoryRow: View {
    let run: RunRecord

    @State private var isExporting = false
    @State private var gpxURL: URL?
    @State private var showShareSheet = false
    @State private var exportError: String?
    @State private var showError = false

    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top line: date + feeling + share button
            HStack {
                Text(formattedDate)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()

                // GPX share button
                Button {
                    exportGPX()
                } label: {
                    if isExporting {
                        ProgressView()
                            .tint(.cyan)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15))
                            .foregroundStyle(.cyan)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                Text(feelingEmoji)
                    .font(.title3)
                Text(feelingLabel)
                    .font(.caption.bold())
                    .foregroundStyle(feelingColor)
            }

            // Stats grid: 2 rows × 4 columns
            HStack(spacing: 0) {
                statCell(label: "Pace", value: run.paceFormatted, unit: "/mi")
                statCell(label: "CCI",
                         value: cciString, unit: "")
                statCell(label: "SPM",
                         value: spmString, unit: "")
                statCell(label: "Zone",
                         value: "\(run.heartRateZone)", unit: "")
            }

            HStack(spacing: 0) {
                statCell(label: "Time", value: run.elapsedFormatted, unit: "")
                statCell(label: "Dist",
                         value: String(format: "%.2f", run.distanceMiles),
                         unit: "mi")
                statCell(label: "Speed",
                         value: String(format: "%.1f", run.avgSpeedMPH),
                         unit: "mph")
                statCell(label: "Steps",
                         value: "\(run.totalSteps)", unit: "")
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showShareSheet) {
            if let url = gpxURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert("Export Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    // MARK: - GPX Export

    private func exportGPX() {
        isExporting = true
        Task {
            do {
                let url = try await GPXExporter.export(run: run)
                await MainActor.run {
                    gpxURL = url
                    showShareSheet = true
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    showError = true
                    isExporting = false
                }
            }
        }
    }

    // MARK: - Stat Cell

    private func statCell(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(yellow)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy  h:mm a"
        return f.string(from: run.date)
    }

    private var cciString: String {
        guard let re = run.runningEconomy else { return "—" }
        return String(format: "%.1f", re.overallCCI)
    }

    private var spmString: String {
        let spm = run.avgStepsPerMin
        guard spm > 0 else { return "—" }
        return String(format: "%.0f", spm)
    }

    private var feelingEmoji: String {
        switch run.feelingRating {
        case 3:  return "😊"
        case 2:  return "😐"
        case 1:  return "😩"
        default: return "—"
        }
    }

    private var feelingLabel: String {
        switch run.feelingRating {
        case 3:  return "GREAT"
        case 2:  return "NOT BAD"
        case 1:  return "BAD"
        default: return ""
        }
    }

    private var feelingColor: Color {
        switch run.feelingRating {
        case 3:  return .green
        case 2:  return .yellow
        case 1:  return .red
        default: return .gray
        }
    }
}

// MARK: - Share Sheet (UIActivityViewController wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) { }
}
