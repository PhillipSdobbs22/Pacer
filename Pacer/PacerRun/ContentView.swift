//
//  ContentView.swift
//  PacerRun
//
//  Standalone PaceGauge UI for Apple Watch.
//  Five screens: settings → gauge → stopped → feeling → summary.
//  Display auto-blanks after 5 seconds to save battery;
//  wrist raise wakes it.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = WatchPaceViewModel()
    @State private var displayOn = true
    @State private var showTrashConfirm = false
    @State private var displayTimer: Timer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.showSummary {
                summaryView
            } else if vm.showFeelingPrompt {
                FeelingRatingView { rating in
                    vm.save(withRating: rating)
                }
            } else if vm.isPaused {
                stoppedView
            } else if vm.isActive {
                activeView
            } else {
                startView
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && vm.isActive && !vm.isPaused {
                wakeDisplay()
            }
        }
    }

    // MARK: - Display Timer

    private func wakeDisplay() {
        displayTimer?.invalidate()
        displayOn = true
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: 7.0, repeats: false
        ) { _ in
            Task { @MainActor in displayOn = false }
        }
    }

    // MARK: - Start Screen

    private var startView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("PaceGauge")
                    .font(.system(size: 16, weight: .bold,
                                  design: .rounded))
                    .foregroundColor(.white)

                // Tortoise pace setter
                HStack {
                    Text("\u{1F422}")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.tortoisePace,
                        in: 0.5...vm.harePace - 0.5,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.tortoisePace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.orange)
                    }
                }

                // Goal pace setter
                HStack {
                    Text("\u{1F3AF}")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.goalPace,
                        in: vm.tortoisePace...vm.harePace,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.goalPace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.yellow)
                    }
                }

                // Hare pace setter
                HStack {
                    Text("\u{1F407}")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.harePace,
                        in: vm.tortoisePace + 0.5...vm.gaugeMax - 0.5,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.harePace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.green)
                    }
                }

                // Max HR setter for zone bar
                HStack {
                    Text("\u{2665}")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.red)
                    Stepper(
                        value: $vm.maxHR,
                        in: 140...220,
                        step: 1
                    ) {
                        Text("Max HR \(Int(vm.maxHR))")
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.red)
                    }
                }

                // Audio splits toggle
                Toggle(isOn: $vm.audioSplitsEnabled) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.cyan)
                        Text("3-min splits")
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.cyan)
                    }
                }
                .tint(.cyan)

                Button {
                    vm.start()
                    wakeDisplay()
                } label: {
                    Label("Start", systemImage: "figure.run")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal, 4)
        }
        .task {
            await vm.requestAuthorization()
        }
    }

    // MARK: - Active Screen

    private var activeView: some View {
        Group {
            if displayOn {
                gaugeScreen
            } else {
                // Blank black screen — tap or raise wrist to wake
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture { wakeDisplay() }
            }
        }
    }

    private var gaugeScreen: some View {
        ZStack {
            // Gauge — fills screen but respects safe area
            PaceGaugeView(
                currentSpeed: vm.currentSpeedMPH,
                avgSpeed: vm.avgSpeedMPH,
                tortoise: vm.tortoisePace,
                hare: vm.harePace,
                gaugeMax: vm.gaugeMax
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Elapsed time — centered inside arc, semi-transparent, stretched wide
            Text(vm.elapsedFormatted)
                .font(.system(size: 54, weight: .bold,
                              design: .rounded))
                .foregroundColor(.white)
                .opacity(0.30)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .offset(y: 16)

            // HR zone bar — top of screen
            VStack {
                HRZoneBarView(heartRate: vm.heartRate,
                              maxHR: vm.maxHR)
                    .padding(.horizontal, 4)
                Spacer()
            }
            .offset(y: -10)

            // END button bottom-center — red filled capsule
            VStack {
                Spacer()
                Button {
                    displayTimer?.invalidate()
                    vm.pause()
                } label: {
                    Text("PAUSE")
                        .font(.system(size: 13, weight: .bold,
                                      design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.yellow.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Stopped Screen (Resume / Save)

    private var stoppedView: some View {
        VStack(spacing: 16) {
            Text(vm.elapsedFormatted)
                .font(.system(size: 36, weight: .heavy,
                              design: .rounded))
                .foregroundColor(.white)
                .opacity(0.8)

            Text("Paused")
                .font(.system(size: 18, weight: .bold,
                              design: .rounded))
                .foregroundColor(.yellow)

            HStack(spacing: 12) {
                Button {
                    vm.resume()
                    wakeDisplay()
                } label: {
                    Text("Resume")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    vm.promptFeeling()
                } label: {
                    Text("END")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    // MARK: - Summary Screen

    /// Format pace from seconds-per-mile to "M:SS" string.
    private func formatPace(_ secondsPerMile: Double?) -> String {
        guard let ps = secondsPerMile, ps.isFinite, ps > 0 else {
            return "--:--"
        }
        let rounded = Int(ps.rounded())
        let paceMin = rounded / 60
        let paceSec = rounded % 60
        return String(format: "%d:%02d", paceMin, paceSec)
    }

    /// Format elapsed seconds to "M:SS" or "H:MM:SS".
    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    private var summaryView: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("PacerRun Complete")
                    .font(.system(size: 16, weight: .bold,
                                  design: .rounded))
                    .foregroundColor(.white)

                // ── Session-Wide Stats ──

                // Total elapsed time — hero number
                Text(formatElapsed(vm.summaryElapsedSeconds))
                    .font(.system(size: 36, weight: .heavy,
                                  design: .rounded))
                    .foregroundColor(.white)

                Text("total time")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))

                // Overall pace, HR zone, SPM — compact row
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text(formatPace(vm.summaryPaceSecondsPerMile))
                            .font(.system(size: 20, weight: .bold,
                                          design: .rounded))
                            .foregroundColor(.cyan)
                        Text("min/mi")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    VStack(spacing: 2) {
                        Text("Z\(vm.summaryHRZone)")
                            .font(.system(size: 20, weight: .bold,
                                          design: .rounded))
                            .foregroundColor(.red)
                        Text("HR zone")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    VStack(spacing: 2) {
                        Text(String(format: "%.0f", vm.summaryAvgStepsPerMin))
                            .font(.system(size: 20, weight: .bold,
                                          design: .rounded))
                            .foregroundColor(.yellow)
                        Text("spm")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.vertical, 4)

                // Distance and avg speed
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.2f", vm.totalDistanceMiles))
                            .font(.system(size: 16, weight: .bold,
                                          design: .rounded))
                            .foregroundColor(.green)
                        Text("miles")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", vm.avgSpeedMPH))
                            .font(.system(size: 16, weight: .bold,
                                          design: .rounded))
                            .foregroundColor(.green)
                        Text("avg mph")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                // Goal pace comparison
                let diff = vm.avgSpeedMPH - vm.goalPace
                let sign = diff >= 0 ? "+" : ""
                Text(String(format: "%@%.2f mph of goal",
                            sign, diff))
                    .font(.system(size: 13, weight: .semibold,
                                  design: .rounded))
                    .foregroundColor(diff >= 0 ? .green : .orange)
                    .padding(.top, 2)

                // ── Feeling Rating ──
                HStack(spacing: 6) {
                    Text(feelingEmoji(vm.feelingRating))
                        .font(.system(size: 18))
                    Text(feelingLabel(vm.feelingRating))
                        .font(.system(size: 13, weight: .semibold,
                                      design: .rounded))
                        .foregroundColor(feelingColor(vm.feelingRating))
                }
                .padding(.top, 2)

                // ── Running Economy Results ──
                if let re = vm.reSummary {
                    Divider()
                        .background(Color.white.opacity(0.3))
                        .padding(.vertical, 4)

                    Text("Running Economy")
                        .font(.system(size: 15, weight: .bold,
                                      design: .rounded))
                        .foregroundColor(.cyan)

                    // Overall CCI — big number
                    Text(String(format: "%.1f", re.overallCCI))
                        .font(.system(size: 36, weight: .heavy,
                                      design: .rounded))
                        .foregroundColor(.cyan)

                    Text("CCI (lower is better)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))

                    // Trend
                    if re.finalTrend != .none {
                        HStack(spacing: 4) {
                            Image(systemName: trendIcon(re.finalTrend))
                                .foregroundColor(trendColor(re.finalTrend))
                            Text(re.finalTrend.rawValue.capitalized)
                                .font(.system(size: 14, weight: .semibold,
                                              design: .rounded))
                                .foregroundColor(trendColor(re.finalTrend))
                        }
                        .padding(.top, 2)
                    }

                    // Best / Worst intervals
                    if re.intervalCount > 1 {
                        HStack(spacing: 16) {
                            VStack(spacing: 2) {
                                Text("Best")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                                Text(String(format: "%.1f", re.bestIntervalCCI))
                                    .font(.system(size: 16, weight: .bold,
                                                  design: .rounded))
                                    .foregroundColor(.green)
                                Text("split \(re.bestIntervalNumber)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Text("Worst")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                                Text(String(format: "%.1f", re.worstIntervalCCI))
                                    .font(.system(size: 16, weight: .bold,
                                                  design: .rounded))
                                    .foregroundColor(.orange)
                                Text("split \(re.worstIntervalNumber)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Weight-normalized CCI
                    if let normCCI = vm.weightNormalizedCCI {
                        VStack(spacing: 2) {
                            Text("Weight-Adjusted")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                            Text(String(format: "%.1f", normCCI))
                                .font(.system(size: 16, weight: .bold,
                                              design: .rounded))
                                .foregroundColor(.white)
                            Text(String(format: "at %.0f lbs",
                                        vm.reTracker.bodyWeightLbs))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.top, 4)
                    }
                }

                // Save / Trash buttons
                HStack(spacing: 12) {
                    Button {
                        vm.dismissSummary()
                    } label: {
                        Text("Save")
                            .font(.system(size: 15, weight: .semibold,
                                          design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                        showTrashConfirm = true
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.top, 8)
                .alert("Delete Activity?", isPresented: $showTrashConfirm) {
                    Button("Delete", role: .destructive) {
                        vm.dismissSummary()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This activity will not be saved.")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Trend Helpers

    private func trendIcon(_ trend: RETrend) -> String {
        switch trend {
        case .improving: return "arrow.down.right"
        case .steady:    return "arrow.right"
        case .fading:    return "arrow.up.right"
        case .none:      return "minus"
        }
    }

    private func trendColor(_ trend: RETrend) -> Color {
        switch trend {
        case .improving: return .green
        case .steady:    return .yellow
        case .fading:    return .orange
        case .none:      return .white
        }
    }

    // MARK: - Feeling Helpers

    private func feelingEmoji(_ rating: Int) -> String {
        switch rating {
        case 3:  return "😊"
        case 2:  return "😐"
        case 1:  return "😩"
        default: return "—"
        }
    }

    private func feelingLabel(_ rating: Int) -> String {
        switch rating {
        case 3:  return "GREAT"
        case 2:  return "NOT BAD"
        case 1:  return "BAD"
        default: return "—"
        }
    }

    private func feelingColor(_ rating: Int) -> Color {
        switch rating {
        case 3:  return .green
        case 2:  return .yellow
        case 1:  return .red
        default: return .white
        }
    }
}



#Preview {
    ContentView()
}
