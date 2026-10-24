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

    /// Tracks which run is currently expanded (nil = all collapsed).
    @State private var expandedRunID: UUID?

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
            // Walking optimal cadence card
            PaceBandCadenceCard(
                bandResult: analysis.walkingResult,
                icon: "figure.walk",
                accentColor: .green
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            // Jogging optimal cadence card
            PaceBandCadenceCard(
                bandResult: analysis.joggingResult,
                icon: "figure.run",
                accentColor: .cyan
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            ForEach(runStore.runs) { run in
                RunHistoryRow(
                    run: run,
                    isExpanded: expandedRunID == run.id,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            expandedRunID = (expandedRunID == run.id)
                                ? nil : run.id
                        }
                    }
                )
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

// MARK: - Pace Band Cadence Card

struct PaceBandCadenceCard: View {
    let bandResult: PaceBandResult
    let icon: String
    let accentColor: Color

    private let cardBG = Color(white: 0.10)

    /// The best recommendation: combined if available, else cross-run, else delta.
    private var displayBucket: CadenceBucket? {
        bandResult.combinedOptimalBucket ?? bandResult.optimalBucket ?? bandResult.deltaOptimalBucket
    }

    /// Label describing which signal is driving the recommendation.
    private var signalLabel: String {
        if bandResult.combinedOptimalBucket != nil {
            if bandResult.optimalBucket != nil && bandResult.deltaOptimalBucket != nil {
                return "Cross-run + Delta"
            } else if bandResult.deltaOptimalBucket != nil {
                return "Delta analysis"
            } else {
                return "Cross-run"
            }
        } else if bandResult.optimalBucket != nil {
            return "Cross-run"
        } else if bandResult.deltaOptimalBucket != nil {
            return "Delta analysis"
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 8) {
            // Title row
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(accentColor)
                Text("\(bandResult.paceBand.rawValue) Optimal Cadence")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                // Speed label
                Text(bandResult.paceBand == .walking ? "≤ 4.2 mph" : "> 4.2 mph")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if let optimal = displayBucket {
                // Big cadence range
                Text("\(Int(optimal.rangeLow))–\(Int(optimal.rangeHigh)) SPM")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(accentColor)

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
                Text("Complete more \(bandResult.paceBand.rawValue.lowercased()) activities to find your optimal cadence.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            // Stats line
            HStack(spacing: 12) {
                miniStat(label: "Runs", value: "\(bandResult.totalRuns)")
                miniStat(label: "Intervals", value: "\(bandResult.totalPairsAnalyzed)")
                miniStat(label: "Deltas", value: "\(bandResult.totalDeltaPairs)")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Detail Line

    @ViewBuilder
    private func detailLine(for bucket: CadenceBucket) -> some View {
        if bucket.sampleCount > 0 && bucket.avgCCI > 0 {
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
            Text(String(format: "Slope: %+.2f  ·  %d delta pairs",
                        gradient, bucket.deltaCount))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Confidence Badge

    private var confidenceBadge: some View {
        let (text, color) = confidenceDisplay(bandResult.confidence)
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
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var isExporting = false
    @State private var gpxURL: URL?
    @State private var showShareSheet = false
    @State private var exportError: String?
    @State private var showError = false

    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top line: date + feeling + share button + chevron
            Button(action: onTap) {
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

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

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

            // MARK: - Expanded Detail View
            if isExpanded {
                expandedDetail
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

    // MARK: - Expanded Detail

    @ViewBuilder
    private var expandedDetail: some View {
        if let re = run.runningEconomy, !re.spmCCIPairs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider().background(Color.white.opacity(0.2))

                // Extra stats row: Max HR, Calories
                extraStatsRow

                // CCI trend banner
                cciTrendBanner(re: re)

                // Best & Worst interval callouts
                bestWorstCallouts(re: re)

                // Interval breakdown table
                intervalTable(pairs: re.spmCCIPairs)

                // Coaching insights
                coachingInsights(re: re)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            VStack(spacing: 6) {
                Divider().background(Color.white.opacity(0.2))
                HStack {
                    statCell(label: "Max HR",
                             value: String(format: "%.0f", run.maxHR),
                             unit: "bpm")
                    statCell(label: "Calories",
                             value: String(format: "%.0f", run.activeCalories),
                             unit: "cal")
                }
                Text("No interval data available for this run.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Extra Stats

    private var extraStatsRow: some View {
        HStack(spacing: 0) {
            statCell(label: "Max HR",
                     value: String(format: "%.0f", run.maxHR),
                     unit: "bpm")
            statCell(label: "Calories",
                     value: String(format: "%.0f", run.activeCalories),
                     unit: "cal")
            statCell(label: "Avg CCI",
                     value: cciString, unit: "")
            statCell(label: "Intervals",
                     value: "\(run.runningEconomy?.intervalCount ?? 0)",
                     unit: "")
        }
    }

    // MARK: - CCI Trend Banner

    private func cciTrendBanner(re: RunREData) -> some View {
        let trendColor: Color = {
            switch re.trend.lowercased() {
            case "improving": return .green
            case "stable":    return .cyan
            default:          return .red
            }
        }()
        let trendIcon: String = {
            switch re.trend.lowercased() {
            case "improving": return "arrow.down.right"
            case "stable":    return "arrow.right"
            default:          return "arrow.up.right"
            }
        }()

        return HStack(spacing: 8) {
            Text("CCI TREND")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Image(systemName: trendIcon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(trendColor)
            Text(re.trend.capitalized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(trendColor)
            Spacer()
            Text(String(format: "%.1f → %.1f",
                        re.bestIntervalCCI, re.worstIntervalCCI))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Best & Worst Callouts

    private func bestWorstCallouts(re: RunREData) -> some View {
        HStack(spacing: 8) {
            // Best interval
            VStack(alignment: .leading, spacing: 4) {
                Text("BEST")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", re.bestIntervalCCI))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("CCI")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                let bestSPM = re.spmCCIPairs.indices.contains(
                    re.bestIntervalNumber - 1)
                    ? re.spmCCIPairs[re.bestIntervalNumber - 1].spm : 0
                Text("Int \(re.bestIntervalNumber) · \(Int(bestSPM)) SPM")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
                    )
            )

            // Worst interval
            VStack(alignment: .leading, spacing: 4) {
                Text("WORST")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", re.worstIntervalCCI))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                    Text("CCI")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                let worstSPM = re.spmCCIPairs.indices.contains(
                    re.worstIntervalNumber - 1)
                    ? re.spmCCIPairs[re.worstIntervalNumber - 1].spm : 0
                Text("Int \(re.worstIntervalNumber) · \(Int(worstSPM)) SPM")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Interval Table

    private func intervalTable(pairs: [SPMCCIPairRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("3-MIN INTERVAL BREAKDOWN")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 6)

            // Header
            HStack(spacing: 0) {
                Text("#")
                    .frame(width: 28, alignment: .leading)
                Text("SPM")
                    .frame(maxWidth: .infinity)
                Text("CCI")
                    .frame(maxWidth: .infinity)
                Text("Δ CCI")
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.vertical, 4)

            Divider().background(Color.white.opacity(0.15))

            // Rows
            ForEach(Array(pairs.enumerated()), id: \.offset) { idx, pair in
                let isBest = (idx + 1 == run.runningEconomy?.bestIntervalNumber)
                let isWorst = (idx + 1 == run.runningEconomy?.worstIntervalNumber)
                let delta: Double? = idx > 0
                    ? pair.cci - pairs[idx - 1].cci : nil

                HStack(spacing: 0) {
                    Text("\(idx + 1)")
                        .frame(width: 28, alignment: .leading)
                        .foregroundStyle(
                            isBest ? .green :
                            isWorst ? .red :
                            .white.opacity(0.5)
                        )
                        .fontWeight(isBest || isWorst ? .bold : .regular)

                    Text(String(format: "%.0f", pair.spm))
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.white)

                    Text(String(format: "%.1f", pair.cci))
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(
                            isBest ? .green :
                            isWorst ? .red :
                            .white
                        )
                        .fontWeight(isBest || isWorst ? .semibold : .regular)

                    Group {
                        if let d = delta {
                            Text(String(format: "%+.1f", d))
                                .foregroundStyle(d <= 0 ? .green : .red)
                        } else {
                            Text("—")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.vertical, 5)
                .background(
                    isBest ? Color.green.opacity(0.04) :
                    isWorst ? Color.red.opacity(0.04) :
                    Color.clear
                )

                if idx < pairs.count - 1 {
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
    }

    // MARK: - Coaching Insights

    private func coachingInsights(re: RunREData) -> some View {
        let insights = RunCoachingEngine.generateInsights(
            run: run, re: re)

        return VStack(alignment: .leading, spacing: 8) {
            Text("COACHING INSIGHTS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))

            ForEach(insights, id: \.title) { insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: insight.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(insight.color)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(insight.color)
                        Text(insight.body)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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

// MARK: - Coaching Insight Model

struct CoachingInsight {
    let icon: String
    let color: Color
    let title: String
    let body: String
}

// MARK: - Coaching Engine

/// Generates context-aware coaching insights from a run's interval data.
/// Accounts for warm-up HR lag, cardiac drift, and intentional variation.
enum RunCoachingEngine {

    static func generateInsights(run: RunRecord, re: RunREData) -> [CoachingInsight] {
        var insights: [CoachingInsight] = []
        let pairs = re.spmCCIPairs
        guard pairs.count >= 2 else { return insights }

        // 1. Warm-up detection: is the best interval #1 or #2?
        let warmUpArtifact = re.bestIntervalNumber <= 2
            && pairs.count >= 4
        if warmUpArtifact {
            let laterBest = pairs.dropFirst(2).min(by: { $0.cci < $1.cci })
            let laterBestCCI = laterBest?.cci ?? re.bestIntervalCCI
            let gapFromBest = laterBestCCI - re.bestIntervalCCI
            if gapFromBest > 1.5 {
                insights.append(CoachingInsight(
                    icon: "heart.text.clipboard",
                    color: .orange,
                    title: "Warm-up HR lag likely",
                    body: String(format:
                        "Best CCI (%.1f) came in interval %d before HR " +
                        "stabilized. Your true steady-state best is " +
                        "closer to %.1f. Early intervals inflate " +
                        "efficiency — look at intervals 3+ for real form.",
                        re.bestIntervalCCI, re.bestIntervalNumber,
                        laterBestCCI)
                ))
            } else {
                // Best interval early but close to later intervals
                insights.append(CoachingInsight(
                    icon: "star",
                    color: .yellow,
                    title: "Strong start",
                    body: String(format:
                        "Best CCI (%.1f) in interval %d and you held " +
                        "similar economy throughout — your warm-up form " +
                        "carried into the run.",
                        re.bestIntervalCCI, re.bestIntervalNumber)
                ))
            }
        } else if re.bestIntervalNumber >= 3 {
            insights.append(CoachingInsight(
                icon: "star",
                color: .yellow,
                title: "Peak form mid-run",
                body: String(format:
                    "Best CCI (%.1f) came in interval %d — you found " +
                    "your most efficient form after warming up, which " +
                    "is the ideal pattern.",
                    re.bestIntervalCCI, re.bestIntervalNumber)
            ))
        }

        // 2. Cardiac drift detection
        let firstHalfCCI = pairs.prefix(pairs.count / 2)
            .map(\.cci).reduce(0, +) / Double(pairs.count / 2)
        let secondHalfCCI = pairs.suffix(pairs.count / 2)
            .map(\.cci).reduce(0, +) / Double(pairs.count / 2)
        let driftPercent = ((secondHalfCCI - firstHalfCCI) / firstHalfCCI)
            * 100

        // Check if SPM was uniform (GPX limitation)
        let spmSet = Set(pairs.map { Int($0.spm) })
        let uniformSPM = spmSet.count == 1

        if driftPercent > 10 {
            if uniformSPM {
                insights.append(CoachingInsight(
                    icon: "waveform.path.ecg",
                    color: .red,
                    title: "Cardiac drift detected",
                    body: String(format:
                        "CCI rose %.0f%% from first to second half at " +
                        "constant cadence. Your heart worked harder for " +
                        "the same pace — typical in zone %d. Future runs " +
                        "with varied cadence will show if SPM shifts help.",
                        driftPercent, run.heartRateZone)
                ))
            } else {
                insights.append(CoachingInsight(
                    icon: "waveform.path.ecg",
                    color: .red,
                    title: "Cardiac drift detected",
                    body: String(format:
                        "CCI rose %.0f%% from first to second half. " +
                        "Heart rate climbed while pace held — consider " +
                        "starting easier or adjusting cadence earlier.",
                        driftPercent)
                ))
            }
        } else if driftPercent < -5 {
            insights.append(CoachingInsight(
                icon: "arrow.down.heart",
                color: .green,
                title: "Negative split — strong finish",
                body: String(format:
                    "CCI improved %.0f%% in the second half — you got " +
                    "more efficient as the run progressed. Great pacing.",
                    abs(driftPercent))
            ))
        }

        // 3. Mid-run recovery / intentional variation
        if !uniformSPM {
            // Find the largest SPM swing between consecutive intervals
            var maxSwing = 0.0
            var swingIdx = 0
            for i in 1..<pairs.count {
                let swing = abs(pairs[i].spm - pairs[i - 1].spm)
                if swing > maxSwing {
                    maxSwing = swing
                    swingIdx = i
                }
            }
            if maxSwing >= 6 {
                let surgeUp = pairs[swingIdx].spm > pairs[swingIdx - 1].spm
                let cciChange = pairs[swingIdx].cci - pairs[swingIdx - 1].cci
                let cciVerdict = cciChange < 0 ? "improved" : "worsened"
                insights.append(CoachingInsight(
                    icon: "arrow.triangle.swap",
                    color: .cyan,
                    title: surgeUp
                        ? "Cadence surge detected"
                        : "Cadence drop detected",
                    body: String(format:
                        "SPM %@ from %.0f to %.0f at interval %d — " +
                        "CCI %@ by %.1f. %@",
                        surgeUp ? "jumped" : "dropped",
                        pairs[swingIdx - 1].spm, pairs[swingIdx].spm,
                        swingIdx + 1,
                        cciVerdict, abs(cciChange),
                        cciChange < 0
                            ? "The shift helped your economy."
                            : "The shift cost more cardiac effort.")
                ))
            }
        } else if pairs.count >= 4 {
            // All SPMs uniform — note the limitation
            // Check for any mid-run dip (recovery signal)
            var bestDip = 0.0
            var dipIdx = 0
            for i in 2..<pairs.count {
                let dip = pairs[i - 1].cci - pairs[i].cci
                if dip > bestDip {
                    bestDip = dip
                    dipIdx = i
                }
            }
            if bestDip > 1.0 {
                insights.append(CoachingInsight(
                    icon: "clock.arrow.circlepath",
                    color: .cyan,
                    title: "Mid-run recovery",
                    body: String(format:
                        "Interval %d dropped CCI by %.1f — a sign you " +
                        "found a second wind. Future runs with natural " +
                        "cadence variation will reveal if SPM shifts " +
                        "helped.",
                        dipIdx + 1, bestDip)
                ))
            }

            insights.append(CoachingInsight(
                icon: "metronome",
                color: Color.white.opacity(0.6),
                title: "Uniform cadence recorded",
                body: "All intervals show the same SPM — you " +
                    "may have held a steady cadence and varied " +
                    "stride length instead. Try targeting ~180 SPM " +
                    "when jogging and ~150 SPM when walking to " +
                    "see how cadence shifts affect your CCI."
            ))
        }

        return insights
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
