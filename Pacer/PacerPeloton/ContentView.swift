import SwiftUI
import UIKit
import Combine

// MARK: - App-wide colors

private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)
private let raceGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
private let raceRed = Color(red: 1.0, green: 0.36, blue: 0.36)
private let hareColor = Color(red: 0.62, green: 0.85, blue: 1.0)
private let tortoiseColor = Color(red: 1.0, green: 0.69, blue: 0.54)

// MARK: - Root TabView

struct ContentView: View {
    @StateObject private var vm = RideViewModel()

    var body: some View {
        TabView {
            ClimbTab(vm: vm)
                .tabItem {
                    Image(systemName: "mountain.2.fill")
                    Text("Climb")
                }

            HistoryTab(vm: vm)
                .tabItem {
                    Image(systemName: "list.bullet.rectangle.fill")
                    Text("Rides")
                }

            SettingsTab(vm: vm)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }

            RunHistoryTab(runStore: RunStore.shared)
                .tabItem {
                    Image(systemName: "figure.run")
                    Text("Runs")
                }
        }
        .tint(yellow)
        .preferredColorScheme(.dark)
        .task {
            await vm.requestAccess()
            await vm.loadAutoGhostPaces()
        }
    }
}

// MARK: - Climb Tab

struct ClimbTab: View {
    @ObservedObject var vm: RideViewModel
    @AppStorage("bodyWeightLb") private var weightLb: Double = 180
    @AppStorage("climbDistanceFt") private var climbDistanceFt: Double = 1000
    @AppStorage("userAvatar") private var userAvatar: String = "\u{1F60A}"
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("userSex") private var userSex: Int = 0
    @AppStorage("maxHRManual") private var maxHRManual: Int = 0
    @AppStorage("maxHROverride") private var maxHROverride: Bool = false
    @AppStorage("restingHR") private var restingHR: Int = 60

    @State private var showReadinessCheck = false
    @Environment(\.scenePhase) private var scenePhase

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var progress: Double {
        min(max(vm.displayedFt / vm.mountain.totalGainFt, 0), 1)
    }

    private var effectiveMaxHR: Int {
        if maxHROverride && maxHRManual > 0 { return maxHRManual }
        return MaxHRFormula.calculate(age: userAge, sex: userSex)
    }

    var body: some View {
        ZStack {
            navy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    tiles
                    if vm.isRunning {
                        SyncWatchRow(lastSampleDate: vm.lastHRSampleDate)
                    }
                    // Nudge banner when falling back to calorie mode
                    if vm.isCalorieFallback {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Set your age in Settings to unlock HR Zone climbing")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if vm.isRunning && !vm.isPaused && vm.climbMode == .hrZone {
                        zoneIndicator
                    }
                    if !vm.ghosts.isEmpty {
                        PaceGauge(
                            avgPace: avgFtPerMin,
                            nowPace: vm.currentPace,
                            harePace: vm.rabbitGhost?.feetPerMin,
                            tortoisePace: vm.houndGhost?.feetPerMin,
                            statusText: raceStatus,
                            hint: vm.isRunning && !showPaceAdjust ? "Tap the gauge to adjust ghost paces" : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard vm.isRunning else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { showPaceAdjust.toggle() }
                        }
                        if vm.isRunning && showPaceAdjust {
                            paceAdjustPanel
                        }
                    }
                    header
                    progressBar
                    Text("RACE PROFILE")
                        .font(.footnote.bold())
                        .foregroundStyle(yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProfileStrip(
                        progress: progress,
                        ghosts: vm.ghosts.map { g in
                            GhostDot(
                                progress: min(max(g.currentFeet / vm.mountain.totalGainFt, 0), 1),
                                name: g.name,
                                role: g.role,
                                feet: g.currentFeet
                            )
                        },
                        accent: yellow,
                        userAvatar: userAvatar,
                        markers: sprintRestMarkers,
                        goalFt: vm.mountain.totalGainFt,
                        userFeet: vm.displayedFt,
                        userFeetColor: userFeetColor
                    )
                    if !vm.ghosts.isEmpty {
                        Lidar(
                            radarGhosts: vm.ghosts.map { g in
                                RadarGhost(
                                    gap: vm.displayedFt - g.currentFeet,
                                    emoji: g.emoji,
                                    role: g.role
                                )
                            },
                            userAvatar: userAvatar
                        )
                    }
                    if vm.isRunning && !vm.isPaused {
                        sprintRestButtons
                    }
                    if vm.isRunning {
                        sprintRestStats
                    }
                    if vm.isRunning { rpeSlider }
                    if vm.showRideSummary {
                        rideSummaryCard
                    } else {
                        controls
                    }
                    if !vm.isRunning && !vm.showRideSummary { instructions }
                    if !vm.statusMessage.isEmpty {
                        Text(vm.statusMessage).font(.footnote).foregroundStyle(.white)
                    }
                }
                .padding()
            }
        }
        .onReceive(timer) { _ in vm.tick() }
        .onChange(of: vm.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the Health app (which forces a Watch sync):
            // pull the newest heart rate and calories right away.
            if phase == .active && vm.isRunning {
                vm.refreshFromHealth()
            }
        }
        .onChange(of: weightLb) { _, newValue in
            vm.weightLb = newValue
        }
        .onChange(of: climbDistanceFt) { _, newValue in
            vm.climbDistanceFt = newValue
        }
        .onAppear {
            vm.climbDistanceFt = climbDistanceFt
            syncClimbSettings()
        }
        .onChange(of: userAge) { _, _ in syncClimbSettings() }
        .onChange(of: userSex) { _, _ in syncClimbSettings() }
        .onChange(of: maxHRManual) { _, _ in syncClimbSettings() }
        .onChange(of: maxHROverride) { _, _ in syncClimbSettings() }
        .onChange(of: restingHR) { _, _ in syncClimbSettings() }
    }

    /// Set maxHR and restHR on the view model — it auto-selects the climb mode.
    private func syncClimbSettings() {
        vm.maxHR = effectiveMaxHR
        vm.restHR = restingHR
    }

    private var avgFtPerMin: Double {
        guard vm.elapsed > 0 else { return 0 }
        return vm.displayedFt / (vm.elapsed / 60.0)
    }

    // MARK: - Zone indicator (continuous gradient bar)

    /// HRR fraction (0…1) for the current heart rate.
    private var hrrFraction: Double {
        guard let hr = vm.heartRate, effectiveMaxHR > restingHR, hr > restingHR else { return 0 }
        return min(Double(hr - restingHR) / Double(effectiveMaxHR - restingHR), 1.0)
    }

    private var zoneIndicator: some View {
        VStack(spacing: 6) {
            // Climb rate readout
            HStack {
                if let hr = vm.heartRate, hr > 0 {
                    Text("\(hr) bpm")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(String(format: "%.1f ft/min", vm.currentClimbRate))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(yellow)
            }

            // Continuous gradient bar with marker
            GeometryReader { geo in
                let barWidth = geo.size.width
                let markerX = hrrFraction * barWidth

                ZStack(alignment: .leading) {
                    // Gradient track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.3, green: 0.6, blue: 1.0),   // blue
                                    Color(red: 0.3, green: 0.85, blue: 0.4),  // green
                                    Color(red: 1.0, green: 0.85, blue: 0.0),  // yellow
                                    Color(red: 1.0, green: 0.5, blue: 0.15),  // orange
                                    Color(red: 1.0, green: 0.2, blue: 0.15)   // red
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 14)

                    // Sliding marker
                    if vm.heartRate != nil && vm.heartRate! > 0 {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 18, height: 18)
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                            .offset(x: max(0, min(markerX - 9, barWidth - 18)))
                            .animation(.easeOut(duration: 0.3), value: hrrFraction)
                    }
                }
            }
            .frame(height: 20)

            // Zone labels under the bar
            HStack {
                Text("Rest")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let zone = vm.currentZone {
                    Text(zone.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("Max")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 4)
    }

    private func zoneColor(_ zone: HRZone) -> Color {
        switch zone {
        case .zone1: return Color(red: 0.5, green: 0.8, blue: 0.95)
        case .zone2: return Color(red: 0.4, green: 0.85, blue: 0.4)
        case .zone3: return Color(red: 1.0, green: 0.83, blue: 0.0)
        case .zone4: return Color(red: 1.0, green: 0.5, blue: 0.2)
        case .zone5: return Color(red: 1.0, green: 0.25, blue: 0.2)
        }
    }

    // MARK: - Existing views

    private var header: some View {
        HStack {
            Text(vm.mountain.name).font(.title2.bold())
            Spacer()
            Text(etaText).font(.title3.bold())
        }
        .foregroundStyle(.white)
    }

    /// Time left to the summit at your average pace.
    private var etaText: String {
        let goal = vm.mountain.totalGainFt
        if goal > 0 && vm.displayedFt >= goal { return "Summit!" }
        if !vm.isRunning && vm.displayedFt == 0 { return "\(Int(goal)) ft goal" }
        let pace = avgFtPerMin
        guard pace > 0.5, vm.elapsed >= 30 else { return "ETA --" }
        let mins = Int(((goal - vm.displayedFt) / pace).rounded(.up))
        return mins < 60 ? "ETA \(mins) min" : "ETA \(mins / 60) h \(mins % 60) min"
    }

    /// Green = ahead of every ghost, red = last place, yellow = in between.
    private var userFeetColor: Color {
        guard !vm.ghosts.isEmpty else { return yellow }
        let ahead = vm.ghosts.filter { $0.currentFeet > vm.displayedFt }.count
        if ahead == 0 { return raceGreen }
        if ahead == vm.ghosts.count { return raceRed }
        return yellow
    }

    /// One-line race status under the Pace Gauge.
    private var raceStatus: String {
        if !vm.isRunning && vm.displayedFt == 0 { return "Tap START to race" }
        let you = vm.displayedFt
        if let hare = vm.rabbitGhost, you >= hare.currentFeet { return "Ahead of the Hare — keep it up" }
        if let tortoise = vm.houndGhost, you < tortoise.currentFeet { return "The Tortoise is ahead — pick it up" }
        if vm.rabbitGhost != nil { return "Chasing the Hare" }
        return "Ahead of the Tortoise"
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.3))
                Capsule().fill(yellow).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 10)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            Tile(value: vm.heartRate.map { String($0) } ?? "--", label: "HR bpm", icon: "heart.fill", iconColor: .red)
            Tile(value: String(Int(vm.activeKcal)), label: "Active kcal", icon: "flame.fill", iconColor: .orange)
            Tile(value: timeString(vm.elapsed), label: "Time", icon: "clock", iconColor: navy)
        }
    }

    @State private var showPaceAdjust = false

    /// Mid-ride ghost pace steppers (opened by tapping the Pace Gauge).
    private var paceAdjustPanel: some View {
        VStack(spacing: 8) {
            ForEach(vm.ghosts) { ghost in
                HStack(spacing: 12) {
                    Text("\(ghost.emoji) \(ghost.role.displayName)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 110, alignment: .leading)
                    Spacer()
                    Button {
                        vm.adjustGhostPace(ghostId: ghost.id, delta: -2)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Slow down \(ghost.role.displayName)")
                    VStack(spacing: 1) {
                        Text(String(format: "%.0f", ghost.feetPerMin))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(yellow)
                        Text("ft/min")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 60)
                    Button {
                        vm.adjustGhostPace(ghostId: ghost.id, delta: 2)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Speed up \(ghost.role.displayName)")
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private let rpeLabels = ["Really Easy", "Easy", "Not Easy", "Hard", "Really Hard"]

    private var rpeSlider: some View {
        VStack(spacing: 6) {
            HStack {
                Text("RPE")
                    .font(.caption.bold())
                    .foregroundStyle(yellow)
                Spacer()
                Text("\(vm.rpe) — \(rpeLabels[vm.rpe])")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            HStack(spacing: 0) {
                ForEach(0..<5) { level in
                    Button {
                        vm.rpe = level
                    } label: {
                        Text("\(level)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(vm.rpe == level ? rpeColor(level) : Color(white: 0.2))
                            .foregroundStyle(vm.rpe == level ? navy : .white.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(3)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func rpeColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color(red: 0.4, green: 0.85, blue: 0.4)
        case 1: return Color(red: 0.6, green: 0.9, blue: 0.3)
        case 2: return Color(red: 1.0, green: 0.83, blue: 0.0)
        case 3: return Color(red: 1.0, green: 0.5, blue: 0.2)
        case 4: return Color(red: 1.0, green: 0.25, blue: 0.2)
        default: return .gray
        }
    }

    private let feelingOptions: [(emoji: String, label: String)] = [
        ("\u{1F4A9}", "Tired"),
        ("\u{1F60A}", "Good"),
        ("\u{1F4AA}", "Strong")
    ]

    private var feelingPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("HOW DID YOU FEEL?")
                    .font(.caption.bold())
                    .foregroundStyle(yellow)
                Spacer()
                if let f = vm.feeling {
                    Text(f)
                        .font(.title3)
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(feelingOptions.enumerated()), id: \.offset) { _, opt in
                    Button {
                        vm.feeling = opt.emoji
                    } label: {
                        VStack(spacing: 4) {
                            Text(opt.emoji)
                                .font(.system(size: 36))
                            Text(opt.label)
                                .font(.caption2.bold())
                                .foregroundStyle(vm.feeling == opt.emoji ? .white : .white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(vm.feeling == opt.emoji ? Color.white.opacity(0.15) : Color(white: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(vm.feeling == opt.emoji ? yellow : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }
        }
    }

    private var rideSummaryCard: some View {
        VStack(spacing: 12) {
            Text("RIDE COMPLETE")
                .font(.headline.bold())
                .foregroundStyle(yellow)

            HStack(spacing: 8) {
                Tile(value: "\(Int(vm.displayedFt)) ft", label: "Elevation")
                Tile(value: String(Int(vm.activeKcal)), label: "Active kcal")
                Tile(value: timeString(vm.elapsed), label: "Time")
            }

            rpeSlider
            feelingPicker

            HStack(spacing: 10) {
                Button {
                    vm.confirmSave()
                } label: {
                    Text("SAVE")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    vm.discardRide()
                } label: {
                    Text("DISCARD")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var sprintRestMarkers: [MarkerDot] {
        guard vm.mountain.totalGainFt > 0 else { return [] }
        let gain = vm.mountain.totalGainFt
        var dots: [MarkerDot] = []
        for (i, s) in vm.recordedSprintMarkers.enumerated() {
            dots.append(MarkerDot(
                progress: min(max(s.elevationFt / gain, 0), 1),
                isSprint: true,
                label: "S\(i + 1)"
            ))
        }
        for (i, r) in vm.recordedRestMarkers.enumerated() {
            dots.append(MarkerDot(
                progress: min(max(r.elevationFt / gain, 0), 1),
                isSprint: false,
                label: "R\(i + 1)"
            ))
        }
        return dots
    }

    private var sprintRestButtons: some View {
        HStack(spacing: 10) {
            Button {
                vm.startSprint()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16))
                    if vm.isSprinting {
                        Text(String(format: "%.0f", vm.sprintTimeRemaining) + "s")
                            .font(.headline.bold().monospacedDigit())
                    } else {
                        Text("SPRINT")
                            .font(.headline.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    vm.isSprinting
                        ? Color.green.opacity(0.4)
                        : Color.green.opacity(0.15)
                )
                .foregroundStyle(.green)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(vm.isSprinting || vm.isResting)

            Button {
                if vm.isResting {
                    vm.resumeExercise()
                } else {
                    vm.startRest()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cross.fill")
                        .font(.system(size: 16))
                    if vm.isResting {
                        Text("RESUME")
                            .font(.headline.bold())
                    } else {
                        Text("REST")
                            .font(.headline.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    vm.isResting
                        ? Color.red.opacity(0.4)
                        : Color.red.opacity(0.15)
                )
                .foregroundStyle(.red)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(vm.isSprinting)
        }
    }

    private var sprintRestStats: some View {
        HStack(spacing: 20) {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Sprints: \(vm.sprintCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Rests: \(vm.restCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if vm.totalRestTime > 0 || vm.isResting {
                let restSec = Int(vm.totalRestTime + vm.currentRestDuration)
                Text("Rest: \(restSec / 60):\(String(format: "%02d", restSec % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Pre-ride readiness check button (only when stopped)
            if !vm.isRunning {
                Button {
                    showReadinessCheck = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.text.clipboard")
                        Text("Readiness Check")
                            .font(.headline)
                        Spacer()
                        readinessBadge
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if vm.isPaused {
                // Paused: choose to keep going or finish the ride.
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle.fill")
                        Text("RIDE PAUSED")
                            .font(.headline.bold())
                    }
                    .foregroundStyle(yellow)

                    HStack(spacing: 10) {
                        Button {
                            vm.resume()
                        } label: {
                            Label("RESUME", systemImage: "play.fill")
                                .font(.headline.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            vm.stop()
                        } label: {
                            Label("END RIDE", systemImage: "flag.checkered")
                                .font(.headline.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.85))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Button {
                    if vm.isRunning { vm.pause() } else { vm.start(weightLb: weightLb) }
                } label: {
                    Text(vm.isRunning ? "STOP" : "START")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .foregroundStyle(navy)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(isPresented: $showReadinessCheck) {
            ReadinessCheckView(reader: vm.reader) { level in
                vm.applyReadiness(level)
            }
        }
    }

    /// Small badge showing current readiness level.
    private var readinessBadge: some View {
        let level = vm.currentReadiness
        let store = ReadinessStore.shared
        return HStack(spacing: 4) {
            Text(level.emoji)
                .font(.body)
            Text(store.hasCheckedToday ? level.rawValue : "Not checked")
                .font(.caption.bold())
                .foregroundStyle(store.hasCheckedToday ? colorForReadiness(level) : .gray)
        }
    }

    private func colorForReadiness(_ level: ReadinessLevel) -> Color {
        switch level {
        case .fresh:    return .green
        case .normal:   return .yellow
        case .fatigued: return .red
        }
    }

    private var instructions: some View {
        Group {
            if vm.climbMode == .hrZone {
                Text("1. On your Watch, start any workout.\n2. Tap START here at the same moment.\n3. Your HR zone determines your climbing speed — higher effort = faster ascent. Equal across all workout types.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("1. On your Watch, start the Indoor Cycle workout.\n2. Tap START here at the same moment.\n3. Pedal. Climb is counted from calories after you tap START.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - History Tab

struct HistoryTab: View {
    @ObservedObject var vm: RideViewModel
    @State private var rides: [RideRecord] = []

    var body: some View {
        NavigationStack {
            ZStack {
                navy.ignoresSafeArea()
                Group {
                    if rides.isEmpty {
                        VStack(spacing: 12) {
                            HStack(spacing: 20) {
                                Image(systemName: "figure.outdoor.cycle")
                                Image(systemName: "figure.run")
                                Image(systemName: "figure.strengthtraining.traditional")
                            }
                            .font(.system(size: 48))
                            .foregroundStyle(yellow)
                            Text("No workouts yet")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            Text("Complete a climb to see your history here.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding()
                    } else {
                        List {
                            ForEach(rides) { ride in
                                historyRow(ride)
                                    .listRowBackground(Color(white: 0.12))
                            }
                            .onDelete(perform: deleteRide)
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Rides")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { reloadRides() }
        }
    }

    private func reloadRides() {
        rides = RideStore.shared.rides
    }

    private func deleteRide(at offsets: IndexSet) {
        for index in offsets {
            let ride = rides[index]
            RideStore.shared.delete(ride.id)
        }
        reloadRides()
    }

    private func historyRow(_ ride: RideRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ride.label ?? dateString(ride.date))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if let feeling = ride.feeling {
                    Text(feeling)
                        .font(.title3)
                }
            }

            HStack(spacing: 16) {
                Label("\(Int(ride.peakFeet)) ft", systemImage: "mountain.2")
                Label("\(Int(ride.activeKcal)) kcal", systemImage: "flame")
                Label(durationString(ride.duration), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 16) {
                Text("\(String(format: "%.1f", ride.avgFeetPerMin)) ft/min avg")
                    .foregroundStyle(yellow)
                if let rpe = ride.rpe {
                    Text(rpeLabel(rpe))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }

    private func dateString(_ date: Date) -> String {
        PacerFormatters.mediumDateTime.string(from: date)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    @ObservedObject var vm: RideViewModel
    @AppStorage("bodyWeightLb") private var weightLb: Double = 180
    @AppStorage("climbDistanceFt") private var climbDistanceFt: Double = 1000
    @AppStorage("userAvatar") private var userAvatar: String = "\u{1F60A}"
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("userSex") private var userSex: Int = 0
    @AppStorage("maxHRManual") private var maxHRManual: Int = 0
    @AppStorage("maxHROverride") private var maxHROverride: Bool = false
    @AppStorage("restingHR") private var restingHR: Int = 60

    // Rabbit & Hound ghost state
    @State private var rabbitEnabled = true
    @State private var rabbitPace: Double = 15
    @State private var rabbitCustom = false   // true = user overrode auto value
    @State private var houndEnabled = true
    @State private var houndPace: Double = 4
    @State private var houndCustom = false

    // Customize sheets
    @State private var showRabbitPicker = false
    @State private var showHoundPicker = false
    @State private var showHealthImport = false

    // Profile loading state
    @State private var loadingProfile = false

    private var calculatedMaxHR: Int {
        MaxHRFormula.calculate(age: userAge, sex: userSex)
    }

    private var effectiveMaxHR: Int {
        if maxHROverride && maxHRManual > 0 { return maxHRManual }
        return calculatedMaxHR
    }

    private var sexLabel: String {
        switch userSex {
        case 1: return "Male"
        case 2: return "Female"
        default: return "Not Set"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your avatar") {
                    let avatars = ["\u{1F4A9}", "\u{1F60A}", "\u{1F4AA}"]
                    let labels = ["Poop", "Smiley", "Strong"]
                    let descriptions = [
                        "Choose me if you're tired and feeling poopy.",
                        "Choose me if you feel good and ready to play.",
                        "Choose me if you're feeling strong today."
                    ]
                    HStack(spacing: 12) {
                        ForEach(Array(avatars.enumerated()), id: \.offset) { idx, emoji in
                            Button {
                                userAvatar = emoji
                            } label: {
                                VStack(spacing: 4) {
                                    Text(emoji)
                                        .font(.system(size: 32))
                                    Text(labels[idx])
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                    Text(descriptions[idx])
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(userAvatar == emoji ? Color.accentColor.opacity(0.15) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(userAvatar == emoji ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Profile
                Section {
                        Button {
                            loadingProfile = true
                            Task {
                                let profile = await vm.loadHealthProfile()
                                if let age = profile.age, age > 0 {
                                    userAge = age
                                }
                                if let isFemale = profile.isFemale {
                                    userSex = isFemale ? 2 : 1
                                }
                                loadingProfile = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                                Text(loadingProfile ? "Loading…" : "Auto-fill from Apple Health")
                            }
                        }
                        .disabled(loadingProfile)

                        HStack {
                            Text("Age")
                            Spacer()
                            TextField("Age", value: $userAge, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }

                        Picker("Sex", selection: $userSex) {
                            Text("Not Set").tag(0)
                            Text("Male").tag(1)
                            Text("Female").tag(2)
                        }

                        Text("Age and sex are used to calculate your max heart rate. You can override them anytime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if vm.isCalorieFallback {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Set your age to unlock HR Zone climbing. Until then, climbing is based on calories.")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                    } header: {
                        Text("Profile")
                    }

                    Section {
                        if userAge > 0 {
                            HStack {
                                Text("Calculated")
                                Spacer()
                                Text("\(calculatedMaxHR) bpm")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Using \(MaxHRFormula.formulaName(sex: userSex)) formula for \(sexLabel.lowercased()), age \(userAge).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Enter your age above to calculate max HR.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Manual override", isOn: $maxHROverride)

                        if maxHROverride {
                            HStack {
                                Text("Max HR")
                                Spacer()
                                TextField("bpm", value: $maxHRManual, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("bpm")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Use this if you know your true max HR from a lab test or field test.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if effectiveMaxHR > 0 {
                            HStack {
                                Text("Active Max HR")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(effectiveMaxHR) bpm")
                                    .fontWeight(.bold)
                                    .foregroundStyle(yellow)
                            }
                        }
                    } header: {
                        Text("Max Heart Rate")
                    }

                    Section {
                        HStack {
                            Text("Resting HR")
                            Spacer()
                            TextField("bpm", value: $restingHR, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                            Text("bpm")
                                .foregroundStyle(.secondary)
                        }
                        Text("Used for the Heart Rate Reserve (HRR) climb formula. A typical resting HR is 50–80 bpm. Lower values mean a wider reserve range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Resting Heart Rate")
                    }

                    Section {
                        // Reference table showing sample HRR% → ft/min from the continuous formula
                        let samplePoints: [(label: String, hrrPct: Double)] = [
                            ("Rest", 0.0),
                            ("20% HRR", 0.2),
                            ("40% HRR", 0.4),
                            ("60% HRR", 0.6),
                            ("80% HRR", 0.8),
                            ("100% HRR", 1.0)
                        ]
                        ForEach(samplePoints, id: \.label) { point in
                            let rate = 1.5 * exp(3.5 * point.hrrPct)
                            let bpm: String = {
                                if effectiveMaxHR > 0 && restingHR > 0 {
                                    let hr = Int(Double(restingHR) + point.hrrPct * Double(effectiveMaxHR - restingHR))
                                    return "\(hr) bpm"
                                }
                                return "\(Int(point.hrrPct * 100))%"
                            }()
                            HStack {
                                Text(point.label)
                                    .font(.system(.body, design: .rounded).bold())
                                    .frame(width: 80, alignment: .leading)
                                Text(bpm)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f ft/min", rate))
                                    .font(.system(.body, design: .rounded).bold())
                                    .foregroundStyle(yellow)
                            }
                            .font(.subheadline)
                        }
                        Text("Climb rate uses a continuous exponential curve (Karvonen HRR). Small HR increases at high effort produce large pace jumps — mimicking real altitude climbing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Climb Rate Reference")
                    }

                Section("Body weight") {
                    TextField("Pounds", value: $weightLb, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section("Climb distance") {
                    HStack {
                        Text("Goal")
                        Spacer()
                        TextField("Feet", value: $climbDistanceFt, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("ft")
                            .foregroundStyle(.secondary)
                    }
                    Text("Default is 1,000 ft. Mt Whitney is 6,100 ft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    // MARK: Hare row 🐇
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\u{1F407} Hare")
                                .font(.headline)
                            Spacer()
                            Toggle("", isOn: $rabbitEnabled)
                                .labelsHidden()
                        }
                        if rabbitEnabled {
                            Text("The ghost you're chasing — set to your best pace.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Pace")
                                Spacer()
                                TextField("ft/min", value: $rabbitPace, format: .number.precision(.fractionLength(0)))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    .onChange(of: rabbitPace) { _, _ in rabbitCustom = true }
                                Text("ft/min")
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    showRabbitPicker = true
                                } label: {
                                    Label("Customize", systemImage: "slider.horizontal.3")
                                        .font(.caption.bold())
                                }
                                if rabbitCustom {
                                    Button {
                                        if let pace = vm.autoRabbitPace {
                                            rabbitPace = (pace).rounded()
                                        }
                                        rabbitCustom = false
                                    } label: {
                                        Label("Reset to auto", systemImage: "arrow.counterclockwise")
                                            .font(.caption.bold())
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            if let autoPace = vm.autoRabbitPace, !rabbitCustom {
                                Text("Auto: \(String(format: "%.0f", autoPace)) ft/min (best from last 42 days)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider()

                    // MARK: Tortoise row 🐢
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\u{1F422} Tortoise")
                                .font(.headline)
                            Spacer()
                            Toggle("", isOn: $houndEnabled)
                                .labelsHidden()
                        }
                        if houndEnabled {
                            Text("The ghost you must stay ahead of — even on bad days.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Pace")
                                Spacer()
                                TextField("ft/min", value: $houndPace, format: .number.precision(.fractionLength(0)))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    .onChange(of: houndPace) { _, _ in houndCustom = true }
                                Text("ft/min")
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    showHoundPicker = true
                                } label: {
                                    Label("Customize", systemImage: "slider.horizontal.3")
                                        .font(.caption.bold())
                                }
                                if houndCustom {
                                    Button {
                                        if let pace = vm.autoHoundPace {
                                            houndPace = (pace).rounded()
                                        }
                                        houndCustom = false
                                    } label: {
                                        Label("Reset to auto", systemImage: "arrow.counterclockwise")
                                            .font(.caption.bold())
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            if let autoPace = vm.autoHoundPace, !houndCustom {
                                Text("Auto: \(String(format: "%.0f", autoPace)) ft/min (50% of your 42-day average)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Your Ghosts")
                } footer: {
                    Text("The Hare is the pace you're trying to beat. The Tortoise is the pace you must stay ahead of. Both are auto-calculated from your last 42 days of Apple Health workouts. Tap the Pace Gauge during a ride to adjust ghost paces on the fly.")
                }
            }
            .navigationTitle("Settings")
            // Drag the list down to hide the number pad.
            .scrollDismissesKeyboard(.interactively)
            // "Done" button above the number pad.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .fontWeight(.bold)
                }
            }
            .sheet(isPresented: $showRabbitPicker) {
                GhostPickerView(vm: vm, onSelect: { record in
                    rabbitPace = (record.avgFeetPerMin).rounded()
                    rabbitCustom = true
                    showRabbitPicker = false
                })
            }
            .sheet(isPresented: $showHoundPicker) {
                GhostPickerView(vm: vm, onSelect: { record in
                    houndPace = (record.avgFeetPerMin).rounded()
                    houndCustom = true
                    showHoundPicker = false
                })
            }
            .sheet(isPresented: $showHealthImport) {
                HealthWorkoutPickerView(
                    weightLb: weightLb,
                    climbModeRaw: vm.climbMode == .hrZone ? 1 : 0,
                    maxHR: effectiveMaxHR,
                    vm: vm,
                    onImport: { record in
                        RideStore.shared.save(record)
                        showHealthImport = false
                    }
                )
            }
            .onAppear {
                // Load current ghost state from VM
                if let rabbit = vm.rabbitGhost {
                    rabbitEnabled = true
                    rabbitPace = (rabbit.feetPerMin).rounded()
                    rabbitCustom = true  // already set up
                } else if let pace = vm.autoRabbitPace {
                    rabbitPace = (pace).rounded()
                    rabbitCustom = false
                }

                if let hound = vm.houndGhost {
                    houndEnabled = true
                    houndPace = (hound.feetPerMin).rounded()
                    houndCustom = true
                } else if let pace = vm.autoHoundPace {
                    houndPace = (pace).rounded()
                    houndCustom = false
                }

                // If auto paces haven't loaded yet, kick them off
                if vm.autoRabbitPace == nil || vm.autoHoundPace == nil {
                    Task {
                        await vm.loadAutoGhostPaces()
                        if !rabbitCustom, let pace = vm.autoRabbitPace {
                            rabbitPace = (pace).rounded()
                        }
                        if !houndCustom, let pace = vm.autoHoundPace {
                            houndPace = (pace).rounded()
                        }
                    }
                }
            }
            .onDisappear {
                dismissKeyboard()
                applyGhosts()
            }
        }
    }

    /// Hide the on-screen keyboard (number pad) so the tab bar is reachable.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func applyGhosts() {
        if rabbitEnabled {
            vm.setupRabbitGhost(pace: rabbitPace)
        } else {
            vm.clearRabbitGhost()
        }

        if houndEnabled {
            vm.setupHoundGhost(pace: houndPace)
        } else {
            vm.clearHoundGhost()
        }
    }
}

// MARK: - RPE wording

/// Words for a saved RPE value (0–4), shown in History and ride pickers.
func rpeLabel(_ rpe: Int) -> String {
    let labels = ["Really Easy", "Easy", "Not Easy", "Hard", "Really Hard"]
    return labels.indices.contains(rpe) ? labels[rpe] : "RPE \(rpe)"
}

// MARK: - Heart-rate freshness + Sync Watch

/// Sync Watch: opens this app's page in iOS Settings
/// (Settings → Apps → PacerPeloton). Tapping "Health" there opens
/// the app's Health data-access page, which pushes the Watch's latest
/// heart rate to the iPhone. When the rider swipes back, the app pulls
/// the new readings automatically.
enum HealthAppLauncher {
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Shows how old the latest heart-rate reading is, plus a Sync Watch button.
struct HRFreshnessBar: View {
    let lastSampleDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = lastSampleDate.map { max(0, context.date.timeIntervalSince($0)) }
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: age))
                    .frame(width: 10, height: 10)
                Text(label(for: age))
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    HealthAppLauncher.open()
                } label: {
                    Label("Sync Watch", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(yellow)
                        .foregroundStyle(navy)
                        .clipShape(Capsule())
                }
            }
            .padding(10)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func label(for age: TimeInterval?) -> String {
        guard let age else { return "No heart rate yet — tap Sync Watch" }
        let secs = Int(age)
        let ago = secs < 60 ? "\(secs) sec ago" : "\(secs / 60) min \(secs % 60) sec ago"
        return "Last reading: \(ago)"
    }

    private func color(for age: TimeInterval?) -> Color {
        guard let age else { return .orange }
        if age < 30 { return .green }
        if age < 120 { return yellow }
        return .orange
    }
}

// MARK: - Tile

struct Tile: View {
    let value: String
    let label: String
    var bgColor: Color = .white
    var icon: String? = nil
    var iconColor: Color? = nil

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(iconColor ?? navy)
                }
                Text(label).font(.caption)
            }
        }
        .foregroundStyle(navy)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Mountain Profile

struct GhostDot {
    let progress: Double
    let name: String
    let role: GhostRole
    var feet: Double = 0
}

struct MarkerDot {
    let progress: Double
    let isSprint: Bool
    let label: String
}

struct ProfileStrip: View {
    let progress: Double
    let ghosts: [GhostDot]
    let accent: Color
    var userAvatar: String = "\u{1F60A}"
    var markers: [MarkerDot] = []
    var goalFt: Double = 0
    var userFeet: Double = 0
    var userFeetColor: Color = .white

    private let pts: [CGPoint] = [
        CGPoint(x: 0, y: 88), CGPoint(x: 60, y: 70), CGPoint(x: 120, y: 62),
        CGPoint(x: 180, y: 44), CGPoint(x: 240, y: 36), CGPoint(x: 300, y: 14),
        CGPoint(x: 358, y: 4)
    ]

    private func yAt(_ x: CGFloat) -> CGFloat {
        for i in 1..<pts.count where x <= pts[i].x {
            let a = pts[i - 1], b = pts[i]
            let t = (x - a.x) / (b.x - a.x)
            return a.y + (b.y - a.y) * t
        }
        return pts[pts.count - 1].y
    }

    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / 358
            let sy = geo.size.height / 90
            let cx = CGFloat(progress) * 358
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    for pt in pts { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.2, green: 0.255, blue: 0.361))

                Path { p in
                    p.move(to: CGPoint(x: 0, y: pts[0].y * sy))
                    for pt in pts where pt.x < cx { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: cx * sx, y: yAt(cx) * sy))
                }
                .stroke(accent, lineWidth: 4)

                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    let mx = CGFloat(marker.progress) * 358
                    let my = yAt(mx) * sy
                    if marker.isSprint {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .position(x: mx * sx, y: my - 14)
                    } else {
                        Image(systemName: "cross.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .position(x: mx * sx, y: my - 14)
                    }
                }

                Image(systemName: "flag.checkered")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .position(x: 358 * sx - 12, y: yAt(358) * sy - 16)

                // Climb goal under the summit flag
                Text("\(Int(goalFt)) ft")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .position(x: 358 * sx - 26, y: yAt(358) * sy + 18)

                ForEach(Array(ghosts.enumerated()), id: \.offset) { _, ghost in
                    let gx = CGFloat(ghost.progress) * 358
                    let gy = yAt(gx) * sy
                    Text(ghost.role.emoji)
                        .font(.system(size: 40))
                        .scaleEffect(x: -1, y: 1)   // face uphill (left → right)
                        .position(x: gx * sx, y: gy - 18)
                    Text("\(Int(ghost.feet)) ft")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .position(x: gx * sx, y: gy + 16)
                }

                Text(userAvatar)
                    .font(.system(size: 34))
                    .position(x: cx * sx, y: yAt(cx) * sy - 14)
                Text("\(Int(userFeet)) ft")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(userFeetColor)
                    .position(x: cx * sx, y: yAt(cx) * sy + 18)
            }
        }
        .frame(height: 170)
        .padding(.top, 28)
    }
}

// MARK: - LIDAR (ghost radar with lanes + auto-zoom)

struct RadarGhost {
    /// Your feet minus the ghost's feet (positive = you're ahead).
    let gap: Double
    let emoji: String
    let role: GhostRole
}

struct Lidar: View {
    let radarGhosts: [RadarGhost]
    var userAvatar: String = "\u{1F60A}"

    private let laneHeight: CGFloat = 58

    /// Window widens automatically so ghosts show at their true distance.
    private var halfRange: Double {
        let maxGap = radarGhosts.map { abs($0.gap) }.max() ?? 0
        let needed = maxGap * 1.15
        let steps: [Double] = [50, 100, 150, 200, 300, 500]
        return steps.first(where: { $0 >= needed }) ?? 500
    }

    /// Hare lanes on top, you in the middle, Tortoise lanes on the bottom.
    private var lanes: [RadarGhost?] {
        let hares = radarGhosts.filter { $0.role == .rabbit }.map { Optional($0) }
        let tortoises = radarGhosts.filter { $0.role == .hound }.map { Optional($0) }
        return hares + [nil] + tortoises
    }

    private func color(_ role: GhostRole) -> Color {
        role == .rabbit ? hareColor : tortoiseColor
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("LIDAR")
                    .font(.footnote.bold())
                    .foregroundStyle(hareColor)
                Spacer()
                Text("\u{00B1}\(Int(halfRange)) ft window")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let midX = w / 2
                let usable = midX - 30
                let totalH = laneHeight * CGFloat(lanes.count)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: 0.15))

                    // Lane dividers
                    ForEach(1..<max(lanes.count, 1), id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: w, height: 1)
                            .position(x: midX, y: laneHeight * CGFloat(i))
                    }
                    // Half-window guides
                    ForEach([-0.5, 0.5], id: \.self) { f in
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: totalH)
                            .position(x: midX + CGFloat(f) * usable, y: totalH / 2)
                    }
                    // You are here
                    Rectangle()
                        .fill(yellow)
                        .frame(width: 2, height: totalH)
                        .position(x: midX, y: totalH / 2)

                    ForEach(Array(lanes.enumerated()), id: \.offset) { idx, lane in
                        let laneMid = laneHeight * (CGFloat(idx) + 0.5)
                        if let rg = lane {
                            let c = color(rg.role)
                            Text(rg.role.displayName.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.75))
                                .position(x: 34, y: laneHeight * CGFloat(idx) + 8)

                            let frac = -rg.gap / halfRange
                            let inRange = abs(rg.gap) <= halfRange
                            let x = inRange
                                ? midX + CGFloat(frac) * usable
                                : (rg.gap < 0 ? w - 30 : 30)
                            VStack(spacing: 0) {
                                HStack(spacing: 2) {
                                    if !inRange && rg.gap > 0 {
                                        Text("\u{25C0}").font(.system(size: 9)).foregroundStyle(c)
                                    }
                                    Text(rg.emoji)
                                        .font(.system(size: 26))
                                        .scaleEffect(x: -1, y: 1)   // face direction of travel
                                    if !inRange && rg.gap < 0 {
                                        Text("\u{25B6}").font(.system(size: 9)).foregroundStyle(c)
                                    }
                                }
                                Text(abs(rg.gap) < 1 ? "TIED" : "\(Int(abs(rg.gap))) ft")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(c)
                            }
                            .position(x: x, y: laneMid + 6)
                        } else {
                            Text("\u{25C0} behind")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.75))
                                .position(x: 40, y: laneMid)
                            Text("ahead \u{25B6}")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.75))
                                .position(x: w - 40, y: laneMid)
                            Text(userAvatar)
                                .font(.system(size: 28))
                                .position(x: midX, y: laneMid)
                        }
                    }
                }
            }
            .frame(height: laneHeight * CGFloat(lanes.count))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Pace Gauge

/// Semicircle gauge: Tortoise and Hare paces as markers, needles for your
/// average pace (solid white) and your pace right now (dashed blue).
struct PaceGauge: View {
    let avgPace: Double
    let nowPace: Double
    let harePace: Double?
    let tortoisePace: Double?
    let statusText: String
    var hint: String? = nil

    private let nowColor = Color(red: 0.43, green: 0.78, blue: 1.0)
    private let orangeZone = Color(red: 1.0, green: 0.48, blue: 0.24)
    private let size = CGSize(width: 320, height: 196)
    private var center: CGPoint { CGPoint(x: 160, y: 168) }
    private let radius: CGFloat = 116

    /// Top of the scale: about twice the Hare's pace, rounded up to 5.
    private var scaleMax: Double {
        let base = max((harePace ?? 0) * 2, (tortoisePace ?? 0) * 2,
                       avgPace * 1.15, nowPace * 1.15, 10)
        return (base / 5).rounded(.up) * 5
    }

    private func point(_ v: Double, _ r: CGFloat) -> CGPoint {
        let f = min(max(v / scaleMax, 0), 1)
        let theta = Double.pi * (1 - f)
        return CGPoint(x: center.x + r * CGFloat(cos(theta)),
                       y: center.y - r * CGFloat(sin(theta)))
    }

    private func arc(from v1: Double, to v2: Double) -> Path {
        Path { p in
            let steps = 40
            for i in 0...steps {
                let v = v1 + (v2 - v1) * Double(i) / Double(steps)
                let pt = point(v, radius)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    /// Colored bands: orange below the slower ghost, yellow between, green above the faster.
    private var bands: [(Double, Double, Color)] {
        let paces = [tortoisePace, harePace].compactMap { $0 }.sorted()
        switch paces.count {
        case 2:
            return [(0, paces[0], orangeZone), (paces[0], paces[1], yellow), (paces[1], scaleMax, raceGreen)]
        case 1:
            let lowColor = harePace != nil ? yellow : orangeZone
            return [(0, paces[0], lowColor), (paces[0], scaleMax, raceGreen)]
        default:
            return [(0, scaleMax, raceGreen)]
        }
    }

    private func needle(_ v: Double, length: CGFloat) -> Path {
        Path { p in
            p.move(to: center)
            p.addLine(to: point(v, length))
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("PACE GAUGE")
                    .font(.footnote.bold())
                    .foregroundStyle(yellow)
                Spacer()
                Text("ft/min")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }

            ZStack {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    arc(from: band.0, to: band.1)
                        .stroke(band.2, style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                }

                ForEach(markers, id: \.label) { m in
                    Path { p in
                        p.move(to: point(m.pace, radius - 12))
                        p.addLine(to: point(m.pace, radius + 12))
                    }
                    .stroke(Color.white, lineWidth: 3)
                    Text(m.emoji)
                        .font(.system(size: 24))
                        .scaleEffect(x: -1, y: 1)
                        .position(point(m.pace, radius + 30))
                    Text(String(format: "%.0f", m.pace))
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .position(point(m.pace, radius + 52))
                }

                needle(nowPace, length: radius - 16)
                    .stroke(nowColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
                needle(avgPace, length: radius - 22)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .position(center)

                Text("0")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: center.x - radius, y: center.y + 18)
                Text(String(format: "%.0f", scaleMax))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: center.x + radius, y: center.y + 18)
            }
            .frame(width: size.width, height: size.height)

            HStack(spacing: 28) {
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", avgPace))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("— average")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", nowPace))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(nowColor)
                    Text("- - right now")
                        .font(.caption.bold())
                        .foregroundStyle(nowColor)
                }
            }
            Text(statusText)
                .font(.caption.bold())
                .foregroundStyle(.white)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.15, blue: 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private struct Marker { let label: String; let emoji: String; let pace: Double }

    private var markers: [Marker] {
        var list: [Marker] = []
        if let t = tortoisePace { list.append(Marker(label: "tortoise", emoji: GhostRole.hound.emoji, pace: t)) }
        if let h = harePace { list.append(Marker(label: "hare", emoji: GhostRole.rabbit.emoji, pace: h)) }
        return list
    }
}

// MARK: - Sync Watch row (button under the HR tile)

struct SyncWatchRow: View {
    let lastSampleDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = lastSampleDate.map { max(0, context.date.timeIntervalSince($0)) }
            GeometryReader { geo in
                let col = (geo.size.width - 16) / 3
                HStack(spacing: 8) {
                    Button {
                        HealthAppLauncher.open()
                    } label: {
                        Text("Sync Watch")
                            .font(.subheadline.bold())
                            .foregroundStyle(navy)
                            .frame(width: col, height: 40)
                            .background(yellow)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dotColor(age))
                            .frame(width: 10, height: 10)
                        Text(label(age))
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(width: col * 2 + 8, alignment: .leading)
                }
            }
            .frame(height: 40)
        }
    }

    private func label(_ age: TimeInterval?) -> String {
        guard let age else { return "No heart rate yet" }
        let secs = Int(age)
        return secs < 60 ? "Last reading: \(secs) sec ago" : "Last reading: \(secs / 60) min \(secs % 60) sec ago"
    }

    private func dotColor(_ age: TimeInterval?) -> Color {
        guard let age else { return .orange }
        if age < 30 { return raceGreen }
        if age < 120 { return yellow }
        return .orange
    }
}

// MARK: - Ghost Picker (for Settings ghost selection)

struct GhostPickerView: View {
    @ObservedObject var vm: RideViewModel
    let onSelect: (RideRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if RideStore.shared.rides.isEmpty {
                    VStack(spacing: 12) {
                        Text("No rides yet")
                            .font(.title3.bold())
                        Text("Complete a ride to see it here. You can then race against your past self.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(RideStore.shared.rides) { ride in
                            Button {
                                onSelect(ride)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ride.label ?? dateString(ride.date))
                                        .font(.headline)
                                    HStack(spacing: 16) {
                                        Label("\(Int(ride.peakFeet)) ft", systemImage: "mountain.2")
                                        Label("\(Int(ride.activeKcal)) kcal", systemImage: "flame")
                                        Label(durationString(ride.duration), systemImage: "clock")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    HStack(spacing: 16) {
                                        Text("\(String(format: "%.1f", ride.avgFeetPerMin)) ft/min avg")
                                        if let rpe = ride.rpe {
                                            Text(rpeLabel(rpe))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.2))
                                                .clipShape(Capsule())
                                        }
                                        if let feeling = ride.feeling {
                                            Text(feeling)
                                                .font(.system(size: 16))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Select Ghost Ride")
            .toolbar {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func dateString(_ date: Date) -> String {
        PacerFormatters.mediumDateTime.string(from: date)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Health Workout Picker

import HealthKit

struct HealthWorkoutPickerView: View {
    let weightLb: Double
    let climbModeRaw: Int
    let maxHR: Int
    @ObservedObject var vm: RideViewModel
    let onImport: (RideRecord) -> Void

    @StateObject private var importer = HealthHistoryImporter()
    @Environment(\.dismiss) private var dismiss
    @State private var importing: UUID? = nil

    private var isHRZoneMode: Bool { climbModeRaw == 1 }

    var body: some View {
        NavigationStack {
            Group {
                if importer.isLoading {
                    ProgressView("Loading workouts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = importer.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await importer.fetchWorkouts() }
                        }
                    }
                    .padding()
                } else if importer.workouts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No workouts found")
                            .font(.title3.bold())
                        Text("Make sure your fitness apps (Garmin, Strava, Nike, etc.) are set to sync workouts to Apple Health.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        if isHRZoneMode {
                            Section {
                                Text("Importing using HR Zone engine (Max HR: \(maxHR) bpm). Elevation is calculated from heart rate zones, equal across all workout types.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(importer.workouts, id: \.uuid) { workout in
                            workoutRow(workout)
                        }
                    }
                }
            }
            .navigationTitle("Apple Health")
            .toolbar {
                Button("Cancel") { dismiss() }
            }
            .task {
                do {
                    try await importer.requestAccess()
                } catch {
                    importer.errorMessage = error.localizedDescription
                    return
                }
                await importer.fetchWorkouts()
            }
        }
    }

    private func workoutRow(_ workout: HKWorkout) -> some View {
        let typeName = HealthHistoryImporter.workoutTypeName(
            workout.workoutActivityType
        )
        let source = workout.sourceRevision.source.name
        let kcal = workout.totalEnergyBurned?.doubleValue(
            for: .kilocalorie()
        ) ?? 0
        let duration = workout.endDate.timeIntervalSince(workout.startDate)
        let massKg = weightLb * 0.45359237
        let estFeet = ClimbMath.feet(kcal: kcal, massKg: massKg)
        let isImporting = importing == workout.uuid

        return Button {
            guard importing == nil else { return }
            importing = workout.uuid
            Task {
                let record: RideRecord?
                if isHRZoneMode {
                    record = await importer.importWorkoutHRZone(
                        workout, maxHR: maxHR
                    )
                } else {
                    record = await importer.importWorkout(
                        workout, massKg: massKg
                    )
                }
                if let record = record {
                    onImport(record)
                }
                importing = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(typeName)
                        .font(.headline)
                    Spacer()
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(HealthHistoryImporter.dateString(workout.startDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Label(
                        HealthHistoryImporter.durationString(duration),
                        systemImage: "clock"
                    )
                    Label("\(Int(kcal)) kcal", systemImage: "flame")
                    if !isHRZoneMode {
                        Label(
                            "\u{2248}\(Int(estFeet)) ft",
                            systemImage: "mountain.2"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isImporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
        .tint(.primary)
        .disabled(isImporting)
    }
}
