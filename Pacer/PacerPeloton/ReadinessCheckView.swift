//
//  ReadinessCheckView.swift
//  PacerPeloton
//
//  Guided pre-ride readiness check: 3-phase orthostatic protocol.
//  Heart rate comes from Apple Health (Watch sync); readings are sorted
//  into phases by when they were measured, so one Sync at the end is
//  enough. A Watch companion app, if installed, also feeds live HR.
//

import SwiftUI
import Combine

// MARK: - Phase Definition

/// The three phases of the Rusko orthostatic protocol.
enum ReadinessPhase: Int, CaseIterable {
    case sitting  = 0   // 2 minutes
    case standing = 1   // 1 minute
    case pedaling = 2   // 4 minutes

    var title: String {
        switch self {
        case .sitting:  return "Sit Still"
        case .standing: return "Stand Up"
        case .pedaling: return "Easy Pedaling"
        }
    }

    var instruction: String {
        switch self {
        case .sitting:
            return "Sit quietly and relax.\nKeep still — let your heart rate settle."
        case .standing:
            return "Stand up slowly.\nStay relaxed, feet shoulder-width apart."
        case .pedaling:
            return "Start pedaling at an easy pace.\nConversation effort — don't push."
        }
    }

    var emoji: String {
        switch self {
        case .sitting:  return "🪑"
        case .standing: return "🧍"
        case .pedaling: return "🚴"
        }
    }

    /// Duration of this phase in seconds.
    var duration: Int {
        switch self {
        case .sitting:  return 120  // 2 min
        case .standing: return 60   // 1 min
        case .pedaling: return 240  // 4 min
        }
    }
}

// MARK: - View Model

/// Where the check is in its flow.
enum ReadinessStage {
    case intro            // before starting
    case running          // phases counting down
    case awaitingSync     // phases done — pull in Watch readings, then score
    case complete         // results shown
}

@MainActor
final class ReadinessCheckViewModel: ObservableObject {
    let reader: HealthReader
    private let connectivity = PhoneConnectivityProvider.shared

    // Flow
    @Published var stage: ReadinessStage = .intro
    @Published var currentPhase: ReadinessPhase = .sitting
    @Published var secondsRemaining: Int = ReadinessPhase.sitting.duration

    // Live HR display
    @Published var currentHR: Double = 0
    @Published var lastSampleDate: Date?

    /// Readings counted in each phase (by when they were measured).
    @Published var phaseCounts: [ReadinessPhase: Int] = [:]

    // Results
    @Published var result: ReadinessCheck?
    /// Phases that had no readings and were filled with your baseline.
    @Published var estimatedPhases: [ReadinessPhase] = []

    // Phase timing — based on the clock, so leaving the app to sync
    // with Health doesn't stall the countdown.
    private var phaseStarts: [ReadinessPhase: Date] = [:]
    private var checkEnd: Date?

    // Readings pushed by the Watch app (if it is ever installed).
    private var liveSamples: [(bpm: Double, date: Date)] = []
    // Readings found in Apple Health for this check.
    private var healthSamples: [(bpm: Double, date: Date)] = []

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var isRunning: Bool { stage == .running }

    init(reader: HealthReader) {
        self.reader = reader
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Start / Stop

    func startCheck() {
        liveSamples.removeAll()
        healthSamples.removeAll()
        phaseCounts = [:]
        estimatedPhases = []
        result = nil
        checkEnd = nil
        currentHR = 0
        lastSampleDate = nil

        // Lay out the phase start times up front.
        var t = Date()
        phaseStarts = [:]
        for phase in ReadinessPhase.allCases {
            phaseStarts[phase] = t
            t = t.addingTimeInterval(TimeInterval(phase.duration))
        }
        currentPhase = .sitting
        secondsRemaining = ReadinessPhase.sitting.duration
        stage = .running

        startHRMonitoring()
        startTimer()
    }

    func cancelCheck() {
        stopTimer()
        stopHRMonitoring()
        stage = .intro
    }

    /// Called when the app comes back to the foreground (e.g. from Health).
    func appBecameActive() {
        guard stage == .running || stage == .awaitingSync else { return }
        tick()                 // catch the countdown up to the real time
        reader.pollNow()       // update the live HR display
        refreshSamples()       // re-count readings per phase
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func phaseEnd(_ phase: ReadinessPhase) -> Date {
        (phaseStarts[phase] ?? Date()).addingTimeInterval(TimeInterval(phase.duration))
    }

    private func tick() {
        guard stage == .running else { return }
        let now = Date()
        // Advance through any phases that finished (even while the app was away).
        while now >= phaseEnd(currentPhase) {
            let next = currentPhase.rawValue + 1
            if next < ReadinessPhase.allCases.count {
                currentPhase = ReadinessPhase.allCases[next]
            } else {
                phasesFinished()
                return
            }
        }
        secondsRemaining = max(0, Int(ceil(phaseEnd(currentPhase).timeIntervalSince(now))))
    }

    private func phasesFinished() {
        stopTimer()
        checkEnd = phaseEnd(.pedaling)
        secondsRemaining = 0
        stage = .awaitingSync
        refreshSamples()
    }

    // MARK: - HR Monitoring

    private func startHRMonitoring() {
        cancellables.removeAll()

        // 1. Apple Health (via Watch sync) — the main source for now.
        reader.onHeartRate = { [weak self] bpm, date in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentHR = bpm
                self.lastSampleDate = date
                self.refreshSamples()
            }
        }
        reader.onEnergy = nil
        reader.onError = nil
        reader.start(from: Date())

        // Show the newest reading we already have, even if it's a bit old.
        reader.fetchLatestHR { [weak self] hr, date in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentHR == 0, let hr = hr else { return }
                self.currentHR = hr
                self.lastSampleDate = date
            }
        }

        // 2. Watch companion app (only if it's installed and running).
        connectivity.$latestHR
            .combineLatest(connectivity.$latestDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hr, date in
                guard let self = self, self.stage == .running,
                      hr > 0, let date = date else { return }
                self.currentHR = hr
                self.lastSampleDate = date
                if self.liveSamples.last?.date != date {
                    self.liveSamples.append((bpm: hr, date: date))
                    self.recount()
                }
            }
            .store(in: &cancellables)
        connectivity.requestStartHR()
    }

    private func stopHRMonitoring() {
        cancellables.removeAll()
        connectivity.requestStopHR()
        reader.stop()
        reader.onHeartRate = nil
    }

    /// Pull every reading measured during the check from Apple Health.
    func refreshSamples() {
        guard let start = phaseStarts[.sitting] else { return }
        let end = checkEnd ?? Date()
        Task { [weak self] in
            guard let self = self else { return }
            let samples = await self.reader.fetchHRSamples(from: start, to: end)
            self.healthSamples = samples
            self.recount()
        }
    }

    /// Readings that belong to one phase, by the time they were measured.
    private func samples(in phase: ReadinessPhase) -> [Double] {
        guard let start = phaseStarts[phase] else { return [] }
        let end = phaseEnd(phase)
        let fromHealth = healthSamples.filter { $0.date >= start && $0.date < end }
        let source = fromHealth.isEmpty
            ? liveSamples.filter { $0.date >= start && $0.date < end }
            : fromHealth
        return source.map { $0.bpm }
    }

    private func recount() {
        var counts: [ReadinessPhase: Int] = [:]
        for phase in ReadinessPhase.allCases {
            counts[phase] = samples(in: phase).count
        }
        phaseCounts = counts
    }

    var missingPhases: [ReadinessPhase] {
        ReadinessPhase.allCases.filter { (phaseCounts[$0] ?? 0) == 0 }
    }

    // MARK: - Scoring

    /// Score the check with whatever readings were found.
    func finishCheck() {
        stopHRMonitoring()
        recount()

        let b = ReadinessStore.shared.baselines
        var estimated: [ReadinessPhase] = []

        let sitting = average(of: samples(in: .sitting))
        let standing = average(of: samples(in: .standing))
        let pedaling = average(of: samples(in: .pedaling))

        // Missing phases fall back to your baseline (a neutral reading).
        let sittingAvg = sitting ?? b.sittingHR
        if sitting == nil { estimated.append(.sitting) }
        let standingAvg = standing ?? (sittingAvg + b.orthostaticDelta)
        if standing == nil { estimated.append(.standing) }
        let pedalingAvg = pedaling ?? b.easyEffortHR
        if pedaling == nil { estimated.append(.pedaling) }

        let check = ReadinessStore.shared.record(
            sittingHR: sittingAvg,
            standingHR: standingAvg,
            easyEffortHR: pedalingAvg,
            updateBaselines: estimated.isEmpty
        )

        estimatedPhases = estimated
        result = check
        stage = .complete
    }

    private func average(of samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }
}

// MARK: - Readiness Check View

struct ReadinessCheckView: View {
    @StateObject private var vm: ReadinessCheckViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Callback when the user accepts a readiness result.
    var onComplete: ((ReadinessLevel) -> Void)?

    init(reader: HealthReader, onComplete: ((ReadinessLevel) -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ReadinessCheckViewModel(reader: reader))
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                switch vm.stage {
                case .complete:
                    if let result = vm.result { resultsView(result) }
                case .awaitingSync:
                    syncView
                case .running:
                    phaseView
                case .intro:
                    introView
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { vm.appBecameActive() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        vm.cancelCheck()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }

    // MARK: - Intro (before starting)

    private var introView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Pre-Ride Readiness")
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text("~7 minute check")
                .font(.title3)
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 16) {
                phaseRow("🪑", "Sit still", "2 min")
                phaseRow("🧍", "Stand up", "1 min")
                phaseRow("🚴", "Easy pedaling", "4 min")
            }
            .padding()
            .background(Color.white.opacity(0.08))
            .cornerRadius(16)

            Text("Measures your autonomic readiness\nand recommends which ghosts to race.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Text("Tip: start an Indoor Cycle workout on your Watch first — it records heart rate every few seconds, so the check gets more readings.")
                .font(.caption)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)

            Spacer()

            Button {
                vm.startCheck()
            } label: {
                Text("Begin Check")
                    .font(.title2.bold())
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .cornerRadius(14)
            }
            .padding(.horizontal)

            Button("Skip — Use Normal") {
                onComplete?(.normal)
                dismiss()
            }
            .foregroundColor(.gray)
            .padding(.bottom, 8)
        }
        .padding()
    }

    private func phaseRow(_ emoji: String, _ label: String, _ time: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title2)
            Text(label)
                .font(.body)
                .foregroundColor(.white)
            Spacer()
            Text(time)
                .font(.body.monospacedDigit())
                .foregroundColor(.gray)
        }
    }

    // MARK: - Active Phase

    private var phaseView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Phase indicator dots
            HStack(spacing: 8) {
                ForEach(ReadinessPhase.allCases, id: \.rawValue) { phase in
                    Circle()
                        .fill(phase == vm.currentPhase ? Color.green : Color.white.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
            }

            Text(vm.currentPhase.emoji)
                .font(.system(size: 64))

            Text(vm.currentPhase.title)
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text(vm.currentPhase.instruction)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Countdown
            Text(timeString(vm.secondsRemaining))
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            // Live HR + Watch status
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.title2)
                    Text(vm.currentHR > 0 ? "\(Int(vm.currentHR))" : "—")
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("bpm")
                        .foregroundColor(.gray)
                }

                Text(readingCountsText)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
            }

            HRFreshnessBar(lastSampleDate: vm.lastSampleDate)

            Spacer()

            // Phase progress
            ProgressView(value: phaseProgress)
                .tint(.green)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
        .padding()
    }

    private var readingCountsText: String {
        let sit = vm.phaseCounts[.sitting] ?? 0
        let stand = vm.phaseCounts[.standing] ?? 0
        let pedal = vm.phaseCounts[.pedaling] ?? 0
        return "Readings — sit \(sit) · stand \(stand) · pedal \(pedal)"
    }

    // MARK: - Sync step (after the phases finish)

    private var syncView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("✅")
                .font(.system(size: 64))

            Text("Phases Complete")
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text("Tap Sync Watch, then tap Health on the Settings page that opens. Swipe back here to pull in your Watch's readings.")
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(ReadinessPhase.allCases, id: \.rawValue) { phase in
                    let count = vm.phaseCounts[phase] ?? 0
                    HStack {
                        Text("\(phase.emoji)  \(phase.title)")
                            .foregroundColor(.white)
                        Spacer()
                        Text(count == 0 ? "No readings" : "\(count) reading\(count == 1 ? "" : "s")")
                            .font(.body.monospacedDigit().bold())
                            .foregroundColor(count == 0 ? .orange : .green)
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.08))
            .cornerRadius(16)

            if !vm.missingPhases.isEmpty {
                Text("Phases with no readings will use your baseline, and this check won't change your baselines.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                HealthAppLauncher.open()
            } label: {
                Label("Sync Watch", systemImage: "arrow.triangle.2.circlepath")
                    .font(.title3.bold())
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.yellow)
                    .cornerRadius(14)
            }
            .padding(.horizontal)

            Button {
                vm.finishCheck()
            } label: {
                Text("See Results")
                    .font(.title2.bold())
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .cornerRadius(14)
            }
            .padding(.horizontal)

            Spacer().frame(height: 8)
        }
        .padding()
    }

    private var phaseProgress: Double {
        let total = Double(vm.currentPhase.duration)
        let elapsed = total - Double(vm.secondsRemaining)
        return elapsed / total
    }

    // MARK: - Results

    private func resultsView(_ check: ReadinessCheck) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Text(check.level.emoji)
                .font(.system(size: 80))

            Text(check.level.rawValue)
                .font(.largeTitle.bold())
                .foregroundColor(colorForLevel(check.level))

            Text(check.level.recommendation)
                .font(.title3)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            if !vm.estimatedPhases.isEmpty {
                Text("Estimated from your baseline (no readings): " +
                     vm.estimatedPhases.map { $0.title }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            // Metrics
            VStack(spacing: 12) {
                metricRow("Resting HR", "\(Int(check.sittingHR)) bpm")
                metricRow("Standing HR", "\(Int(check.standingHR)) bpm")
                metricRow("Δ Sit→Stand", "+\(Int(check.orthostaticDelta)) bpm")
                metricRow("Easy Effort HR", "\(Int(check.easyEffortHR)) bpm")
            }
            .padding()
            .background(Color.white.opacity(0.08))
            .cornerRadius(16)

            // Baselines context
            let baselines = ReadinessStore.shared.baselines
            if baselines.checkCount > 1 {
                VStack(spacing: 4) {
                    Text("Your Baselines")
                        .font(.caption.bold())
                        .foregroundColor(.gray)
                    Text("Rest: \(Int(baselines.sittingHR))  |  Δ: \(Int(baselines.orthostaticDelta))  |  Effort: \(Int(baselines.easyEffortHR))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Button {
                onComplete?(check.level)
                dismiss()
            } label: {
                Text("Accept — Start Ride")
                    .font(.title2.bold())
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(colorForLevel(check.level))
                    .cornerRadius(14)
            }
            .padding(.horizontal)

            // Override buttons
            if check.level != .fresh {
                Button("Override — Ride as Fresh") {
                    onComplete?(.fresh)
                    dismiss()
                }
                .foregroundColor(.green)
            }
            if check.level == .fatigued {
                Button("Override — Ride as Normal") {
                    onComplete?(.normal)
                    dismiss()
                }
                .foregroundColor(.yellow)
            }

            Spacer().frame(height: 8)
        }
        .padding()
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit().bold())
                .foregroundColor(.white)
        }
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func colorForLevel(_ level: ReadinessLevel) -> Color {
        switch level {
        case .fresh:    return .green
        case .normal:   return .yellow
        case .fatigued: return .red
        }
    }
}
