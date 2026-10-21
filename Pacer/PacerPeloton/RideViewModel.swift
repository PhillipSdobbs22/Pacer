import Foundation
import Combine

struct Mountain {
    let name: String
    /// Configurable climb distance in feet. Default 1,000.
    let totalGainFt: Double
    static func climb(distanceFt: Double = 1000) -> Mountain {
        Mountain(name: "YourClimb", totalGainFt: distanceFt)
    }
    static let whitney = climb()   // backward compat alias
}

// MARK: - Climb Engines

enum ClimbMode: Int {
    case calorie = 0
    case hrZone = 1
}

enum ClimbMath {
    /// Fraction of food energy turned into mechanical work on a bike (about 22%).
    static let efficiency = 0.22

    /// Vertical feet climbed for a given amount of active kilocalories.
    static func feet(kcal: Double, massKg: Double) -> Double {
        guard massKg > 0 else { return 0 }
        let joules = kcal * 4184.0
        let meters = joules * efficiency / (massKg * 9.81)
        return meters * 3.28084
    }
}

enum HRZone: Int, CaseIterable {
    case zone1 = 1   // < 60% max HR
    case zone2 = 2   // 60–70%
    case zone3 = 3   // 70–80%
    case zone4 = 4   // 80–90%
    case zone5 = 5   // 90%+

    /// Climbing rate in feet per minute for this zone.
    var feetPerMin: Double {
        switch self {
        case .zone1: return 3
        case .zone2: return 8
        case .zone3: return 18
        case .zone4: return 30
        case .zone5: return 45
        }
    }

    var label: String {
        switch self {
        case .zone1: return "Recovery"
        case .zone2: return "Easy"
        case .zone3: return "Moderate"
        case .zone4: return "Hard"
        case .zone5: return "Max"
        }
    }

    /// HR range description as percentage of max.
    var rangeLabel: String {
        switch self {
        case .zone1: return "< 60%"
        case .zone2: return "60\u{2013}70%"
        case .zone3: return "70\u{2013}80%"
        case .zone4: return "80\u{2013}90%"
        case .zone5: return "90%+"
        }
    }

    /// Heart-rate range in bpm for this zone, matching how zone(hr:maxHR:)
    /// assigns zones (e.g. max 173 → Z2 "104–121 bpm").
    func bpmRangeLabel(maxHR: Int) -> String {
        let m = Double(maxHR)
        func floorBpm(_ pct: Double) -> Int { Int((pct * m).rounded(.up)) }
        switch self {
        case .zone1: return "under \(floorBpm(0.6)) bpm"
        case .zone2: return "\(floorBpm(0.6))\u{2013}\(floorBpm(0.7) - 1) bpm"
        case .zone3: return "\(floorBpm(0.7))\u{2013}\(floorBpm(0.8) - 1) bpm"
        case .zone4: return "\(floorBpm(0.8))\u{2013}\(floorBpm(0.9) - 1) bpm"
        case .zone5: return "\(floorBpm(0.9))+ bpm"
        }
    }

    /// Compact version for the Climb tab zone strip (Z1 shows "<104 bpm").
    func bpmRangeShort(maxHR: Int) -> String {
        if self == .zone1 {
            return "<\(Int((0.6 * Double(maxHR)).rounded(.up))) bpm"
        }
        return bpmRangeLabel(maxHR: maxHR)
    }

    /// Determine the zone for a given HR and max HR.
    static func zone(hr: Double, maxHR: Double) -> HRZone {
        guard maxHR > 0 else { return .zone1 }
        let pct = hr / maxHR
        if pct >= 0.9 { return .zone5 }
        if pct >= 0.8 { return .zone4 }
        if pct >= 0.7 { return .zone3 }
        if pct >= 0.6 { return .zone2 }
        return .zone1
    }
}

// MARK: - Max HR Formulas

enum MaxHRFormula {
    /// Tanaka (2001): 208 − 0.7 × age. Best validated for adults,
    /// especially over 40. Used for males and unspecified sex.
    static func tanaka(age: Int) -> Int {
        Int(208.0 - (0.7 * Double(age)))
    }

    /// Gulati (2010): 206 − 0.88 × age. Developed specifically for
    /// women from a study of 5,437 subjects.
    static func gulati(age: Int) -> Int {
        Int(206.0 - (0.88 * Double(age)))
    }

    /// Pick the right formula based on sex (0 = not set, 1 = male, 2 = female).
    static func calculate(age: Int, sex: Int) -> Int {
        guard age > 0 else { return 0 }
        if sex == 2 { return gulati(age: age) }
        return tanaka(age: age)
    }

    static func formulaName(sex: Int) -> String {
        sex == 2 ? "Gulati" : "Tanaka"
    }
}

// MARK: - View Model

@MainActor
final class RideViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate: Int? = nil
    @Published var activeKcal: Double = 0
    @Published var displayedFt: Double = 0
    @Published var lastDelay: Double? = nil
    @Published var avgDelay: Double? = nil
    @Published var statusMessage: String = ""
    @Published var rpe: Int = 0
    @Published var feeling: String? = nil
    @Published var showRideSummary = false

    // Pause / resume
    @Published private(set) var isPaused = false
    private var pausedAt: Date?
    private var totalPausedTime: TimeInterval = 0
    private var pauseIntervals: [(start: Date, end: Date)] = []

    /// Climbing pace over the last 60 seconds (ft/min) — the "right now" needle.
    @Published private(set) var currentPace: Double = 0
    private var paceHistory: [(elapsed: TimeInterval, feet: Double)] = []
    private static let paceWindow: TimeInterval = 60

    /// End date of the newest heart-rate sample received (for the freshness indicator).
    @Published private(set) var lastHRSampleDate: Date? = nil

    // Ghosts (manual + history can run simultaneously)
    @Published var ghosts: [Ghost] = []

    // Pre-ride readiness
    @Published var currentReadiness: ReadinessLevel = .normal

    // HR Zone mode state
    @Published var currentZone: HRZone? = nil

    // Sprint / Rest state
    @Published var isSprinting = false
    @Published var sprintTimeRemaining: Double = 0
    @Published var isResting = false
    @Published var restStartTime: Date? = nil
    @Published var sprintCount: Int = 0
    @Published var restCount: Int = 0
    @Published var totalRestTime: TimeInterval = 0

    private(set) var recordedSprintMarkers: [SprintMarker] = []
    private(set) var recordedRestMarkers: [RestMarker] = []
    private var currentRestStartElapsed: TimeInterval = 0
    private var currentRestStartElevation: Double = 0
    private static let sprintDuration: Double = 20.0

    var weightLb: Double = 180 {
        didSet { recomputeTarget() }
    }

    var climbDistanceFt: Double = 1000 {
        didSet { mountain = Mountain.climb(distanceFt: climbDistanceFt) }
    }

    /// Current climb mode — auto-selected based on whether max HR is available.
    /// HR Zone when maxHR > 0, Calorie fallback otherwise.
    @Published private(set) var climbMode: ClimbMode = .calorie

    /// Effective max HR used for zone calculations.
    var maxHR: Int = 0 {
        didSet { autoSelectClimbMode() }
    }

    /// True when the app fell back to calorie mode because max HR is unavailable.
    @Published private(set) var isCalorieFallback: Bool = false

    /// Auto-calculated Rabbit pace (best workout pace from last 42 days).
    @Published var autoRabbitPace: Double? = nil
    /// Auto-calculated Tortoise pace (50% of average workout pace from last 42 days).
    @Published var autoHoundPace: Double? = nil

    /// Legacy alias so ContentView .task doesn't break during transition.
    var autoGhostPace: Double? { autoRabbitPace }

    let reader = HealthReader()
    private var startDate = Date()
    private var targetFt: Double = 0
    private var delaySamples: [Double] = []
    private(set) var mountain = Mountain.climb()

    // Ride recording: sample elevation every 5 seconds.
    private var recordedSamples: [ElevationSample] = []
    private var lastSampleTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 5.0

    // For accurate HR zone accumulation between ticks.
    private var lastTickDate: Date?

    func requestAccess() async {
        do {
            try await reader.requestAccess()
        } catch {
            statusMessage = "Health access error: \(error.localizedDescription)"
        }
    }

    /// Read age and biological sex from Apple Health.
    /// Returns (age, isFemale) — either may be nil if not available.
    func loadHealthProfile() async -> (age: Int?, isFemale: Bool?) {
        // Re-request access to ensure DOB/sex permissions are included.
        do {
            try await reader.requestAccess()
        } catch {}
        let age = reader.readAge()
        let sex = reader.readBiologicalSex()
        let isFemale: Bool? = sex.map { $0 == 2 }  // 2 = female
        return (age, isFemale)
    }

    func start(weightLb: Double) {
        self.weightLb = weightLb
        startDate = Date()
        elapsed = 0
        heartRate = nil
        activeKcal = 0
        displayedFt = 0
        targetFt = 0
        lastDelay = nil
        avgDelay = nil
        delaySamples = []
        rpe = 0
        feeling = nil
        showRideSummary = false
        recordedSamples = []
        lastSampleTime = 0
        lastTickDate = nil
        currentZone = nil
        isSprinting = false
        sprintTimeRemaining = 0
        isResting = false
        restStartTime = nil
        sprintCount = 0
        restCount = 0
        totalRestTime = 0
        recordedSprintMarkers = []
        recordedRestMarkers = []
        currentRestStartElapsed = 0
        currentRestStartElevation = 0
        isPaused = false
        pausedAt = nil
        totalPausedTime = 0
        pauseIntervals = []
        lastHRSampleDate = nil
        currentPace = 0
        paceHistory = []
        for g in ghosts { g.reset() }
        isRunning = true

        reader.onHeartRate = { [weak self] bpm, date in
            Task { @MainActor in self?.receiveHeartRate(bpm, date) }
        }
        reader.onEnergy = { [weak self] kcal, date in
            Task { @MainActor in self?.receiveEnergy(kcal, date) }
        }
        reader.onError = { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
        reader.start(from: startDate)
    }

    /// STOP button — pauses the ride. The clock, climb, and ghosts freeze
    /// until the rider taps Resume or End Ride.
    func pause() {
        guard isRunning, !isPaused else { return }
        if isResting { resumeExercise() }
        isSprinting = false
        sprintTimeRemaining = 0
        currentZone = nil
        pausedAt = Date()
        isPaused = true
    }

    /// Continue a paused ride. Paused time is not counted.
    func resume() {
        guard isPaused, let p = pausedAt else { return }
        let now = Date()
        totalPausedTime += now.timeIntervalSince(p)
        pauseIntervals.append((start: p, end: now))
        pausedAt = nil
        isPaused = false
        lastTickDate = nil   // avoid counting the pause in HR-zone climbing
    }

    /// End Ride — finishes the ride and shows the Save / Discard summary.
    func stop() {
        if isPaused, let p = pausedAt {
            pauseIntervals.append((start: p, end: Date()))
        }
        isPaused = false
        pausedAt = nil
        reader.stop()
        isRunning = false
        currentZone = nil
        isSprinting = false
        sprintTimeRemaining = 0
        if isResting { resumeExercise() }
        // Show summary so the user can adjust RPE before saving.
        if elapsed > 30, targetFt > 0 {
            showRideSummary = true
        }
    }

    /// Called when the user taps SAVE on the ride summary.
    func confirmSave() {
        saveRide()
        showRideSummary = false
    }

    /// Called when the user discards the ride from the summary.
    func discardRide() {
        showRideSummary = false
    }

    /// Called twice a second by the screen.
    func tick() {
        if isRunning && !isPaused {
            let now = Date()
            // Seconds since the previous tick (used by the sprint countdown).
            let tickDt = lastTickDate.map { now.timeIntervalSince($0) } ?? 0.5
            elapsed = now.timeIntervalSince(startDate) - totalPausedTime

            // HR Zone climb: accumulate feet based on current zone.
            if climbMode == .hrZone,
               let hr = heartRate, hr > 0, maxHR > 0
            {
                let zone = HRZone.zone(
                    hr: Double(hr), maxHR: Double(maxHR)
                )
                currentZone = zone
                if let lastTick = lastTickDate {
                    let dt = now.timeIntervalSince(lastTick)
                    targetFt += zone.feetPerMin * dt / 60.0
                }
            } else if climbMode == .hrZone {
                currentZone = nil
            }
            lastTickDate = now

            // Sprint countdown.
            if isSprinting {
                sprintTimeRemaining = max(0, sprintTimeRemaining - tickDt)
                if sprintTimeRemaining <= 0 {
                    isSprinting = false
                    sprintTimeRemaining = 0
                }
            }

            // Accumulate rest time while resting.
            if isResting, let restStart = restStartTime {
                totalRestTime += now.timeIntervalSince(restStart)
                restStartTime = now
            }

            // Record elevation sample periodically.
            if elapsed - lastSampleTime >= sampleInterval {
                recordedSamples.append(
                    ElevationSample(elapsed: elapsed, feet: targetFt)
                )
                lastSampleTime = elapsed
            }

            // "Right now" pace: feet gained over the last 60 seconds.
            paceHistory.append((elapsed: elapsed, feet: targetFt))
            while paceHistory.count > 2,
                  paceHistory[1].elapsed <= elapsed - Self.paceWindow {
                paceHistory.removeFirst()
            }
            if let first = paceHistory.first, elapsed - first.elapsed >= 5 {
                currentPace = max(0, (targetFt - first.feet) / ((elapsed - first.elapsed) / 60.0))
            }

            // Update ghost positions.
            for g in ghosts {
                g.update(elapsed: elapsed, mountainGainFt: climbDistanceFt)
            }
        }

        // Ease the shown climb toward the target so calorie jumps look smooth.
        let diff = targetFt - displayedFt
        if abs(diff) < 0.5 {
            displayedFt = targetFt
        } else {
            displayedFt += diff * 0.25
        }
    }

    // MARK: - Sprint / Rest actions

    /// Rider taps the Sprint button — start a 20-second sprint.
    func startSprint() {
        guard isRunning, !isPaused, !isSprinting, !isResting else { return }
        isSprinting = true
        sprintTimeRemaining = Self.sprintDuration
        sprintCount += 1
        recordedSprintMarkers.append(
            SprintMarker(
                elevationFt: targetFt,
                elapsedStart: elapsed,
                duration: Self.sprintDuration
            )
        )
    }

    /// Rider taps Begin Rest — pause climbing effort and record position.
    func startRest() {
        guard isRunning, !isPaused, !isSprinting, !isResting else { return }
        isResting = true
        restStartTime = Date()
        restCount += 1
        currentRestStartElapsed = elapsed
        currentRestStartElevation = targetFt
    }

    /// Rider taps Resume Exercise — end rest and record the rest marker.
    func resumeExercise() {
        guard isResting else { return }
        let duration = elapsed - currentRestStartElapsed
        recordedRestMarkers.append(
            RestMarker(
                elevationFt: currentRestStartElevation,
                elapsedStart: currentRestStartElapsed,
                duration: duration
            )
        )
        isResting = false
        restStartTime = nil
    }

    /// Current rest duration if actively resting.
    var currentRestDuration: TimeInterval {
        guard isResting else { return 0 }
        return elapsed - currentRestStartElapsed
    }

    // MARK: - Rabbit & Hound Ghost Setup

    /// The Rabbit ghost (ahead of you — the pace you're chasing).
    var rabbitGhost: Ghost? {
        ghosts.first(where: { $0.role == .rabbit })
    }

    /// The Hound ghost (behind you — the pace you must stay ahead of).
    var houndGhost: Ghost? {
        ghosts.first(where: { $0.role == .hound })
    }

    /// Set up the Rabbit ghost with a given pace.
    func setupRabbitGhost(pace: Double, name: String = "Hare") {
        ghosts.removeAll(where: { $0.role == .rabbit })
        ghosts.append(Ghost(name: name, feetPerMin: pace, role: .rabbit))
    }

    /// Set up the Hound ghost with a given pace.
    func setupHoundGhost(pace: Double, name: String = "Tortoise") {
        ghosts.removeAll(where: { $0.role == .hound })
        ghosts.append(Ghost(name: name, feetPerMin: pace, role: .hound))
    }

    /// Set up the Rabbit ghost from a saved ride record.
    func setupRabbitFromRecord(_ record: RideRecord) {
        ghosts.removeAll(where: { $0.role == .rabbit })
        ghosts.append(Ghost(record: record, role: .rabbit))
    }

    /// Set up the Hound ghost from a saved ride record.
    func setupHoundFromRecord(_ record: RideRecord) {
        ghosts.removeAll(where: { $0.role == .hound })
        ghosts.append(Ghost(record: record, role: .hound))
    }

    /// Remove the rabbit ghost.
    func clearRabbitGhost() {
        ghosts.removeAll(where: { $0.role == .rabbit })
    }

    /// Remove the hound ghost.
    func clearHoundGhost() {
        ghosts.removeAll(where: { $0.role == .hound })
    }

    /// Remove all ghosts.
    func clearAllGhosts() {
        ghosts.removeAll()
    }

    /// Adjust a ghost's pace mid-ride by a delta (ft/min).
    func adjustGhostPace(ghostId: UUID, delta: Double) {
        if let ghost = ghosts.first(where: { $0.id == ghostId }) {
            ghost.adjustPace(by: delta)
        }
    }

    // MARK: - Readiness-Based Ghost Activation

    /// Apply a readiness level: activate/deactivate ghosts accordingly.
    /// - Fresh  → both Rabbit and Hound active
    /// - Normal → Rabbit only
    /// - Fatigued → Hound only (recovery day)
    func applyReadiness(_ level: ReadinessLevel) {
        currentReadiness = level
        let activeRoles = level.activeRoles  // Set<String>

        // Enable/disable the Rabbit ghost
        if activeRoles.contains("rabbit") {
            if rabbitGhost == nil, let pace = autoRabbitPace {
                setupRabbitGhost(pace: pace)
            }
        } else {
            clearRabbitGhost()
        }

        // Enable/disable the Hound ghost
        if activeRoles.contains("hound") {
            if houndGhost == nil, let pace = autoHoundPace {
                setupHoundGhost(pace: pace)
            }
        } else {
            clearHoundGhost()
        }
    }

    // MARK: - Auto-select climb mode

    /// Automatically picks HR Zone mode when max HR is available,
    /// falls back to Calorie mode otherwise.
    func autoSelectClimbMode() {
        if maxHR > 0 {
            climbMode = .hrZone
            isCalorieFallback = false
        } else {
            climbMode = .calorie
            isCalorieFallback = true
        }
    }

    // MARK: - Auto dual ghost pace from HealthKit

    /// Tortoise pace as a fraction of the 42-day average pace.
    static let tortoiseFraction = 0.50

    /// Load auto-calculated paces for both ghosts:
    /// - Hare (rabbit) = best single workout pace from last 42 days
    /// - Tortoise (hound) = 50% of average workout pace from last 42 days
    /// Falls back to RideStore, then defaults (12 / 6 ft/min).
    func loadAutoGhostPaces() async {
        let massKg = weightLb * 0.45359237
        let effectiveMass = massKg > 0 ? massKg : 81.6

        // Try HealthKit first
        async let bestTask = reader.bestPaceLast42Days(bodyMassKg: effectiveMass)
        async let avgTask = reader.averagePaceLast42Days(bodyMassKg: effectiveMass)
        let best = await bestTask
        let avg = await avgTask

        if let bestPace = best, bestPace > 0 {
            autoRabbitPace = bestPace
        }
        if let avgPace = avg, avgPace > 0 {
            autoHoundPace = avgPace * Self.tortoiseFraction
        }

        // Fallback: RideStore
        let rides = RideStore.shared.rides
        if autoRabbitPace == nil, !rides.isEmpty {
            if let bestRide = rides.max(by: { $0.avgFeetPerMin < $1.avgFeetPerMin }) {
                autoRabbitPace = bestRide.avgFeetPerMin
            }
        }
        if autoHoundPace == nil, !rides.isEmpty {
            let totalPace = rides.reduce(0.0) { $0 + $1.avgFeetPerMin }
            let avg = totalPace / Double(rides.count)
            if avg > 0 { autoHoundPace = avg * Self.tortoiseFraction }
        }

        // Final fallback: defaults for new users
        if autoRabbitPace == nil { autoRabbitPace = 12.0 }
        if autoHoundPace == nil { autoHoundPace = 6.0 }
    }

    /// Legacy shim — kept so the ContentView .task compiles during transition.
    func loadAutoGhostPace() async {
        await loadAutoGhostPaces()
    }

    // MARK: - Private

    /// Ask Apple Health right now for anything new (e.g. after the rider
    /// comes back from the Health app, which forces a Watch sync).
    func refreshFromHealth() {
        reader.pollNow()
    }

    /// True if a sample time falls inside a paused stretch of the ride.
    private func isDuringPause(_ date: Date) -> Bool {
        if isPaused, let p = pausedAt, date >= p { return true }
        return pauseIntervals.contains { date >= $0.start && date <= $0.end }
    }

    private func receiveHeartRate(_ bpm: Double, _ sampleDate: Date) {
        heartRate = Int(bpm.rounded())
        lastHRSampleDate = sampleDate
        let delay = max(0, Date().timeIntervalSince(sampleDate))
        lastDelay = delay
        delaySamples.append(delay)
        avgDelay = delaySamples.reduce(0, +) / Double(delaySamples.count)
    }

    private func receiveEnergy(_ kcal: Double, _ sampleDate: Date) {
        // Calories burned while paused don't count toward the climb.
        guard !isDuringPause(sampleDate) else { return }
        activeKcal += kcal
        if climbMode == .calorie {
            recomputeTarget()
        }
    }

    private func recomputeTarget() {
        if climbMode == .calorie {
            targetFt = ClimbMath.feet(
                kcal: activeKcal, massKg: weightLb * 0.45359237
            )
        }
        // In HR zone mode, targetFt is accumulated in tick().
    }

    private func saveRide() {
        // Only save rides longer than 30 seconds with some elevation.
        guard elapsed > 30, targetFt > 0 else { return }

        // Close any open rest period before saving.
        if isResting { resumeExercise() }

        // Add a final sample at the end.
        recordedSamples.append(
            ElevationSample(elapsed: elapsed, feet: targetFt)
        )

        var record = RideRecord(
            id: UUID(),
            date: startDate,
            mountainName: mountain.name,
            mountainGainFt: mountain.totalGainFt,
            duration: elapsed,
            activeKcal: activeKcal,
            peakFeet: targetFt,
            samples: recordedSamples
        )
        record.rpe = rpe
        record.feeling = feeling
        record.sprintMarkers = recordedSprintMarkers.isEmpty ? nil : recordedSprintMarkers
        record.restMarkers = recordedRestMarkers.isEmpty ? nil : recordedRestMarkers
        RideStore.shared.save(record)
    }
}
