//
//  WatchPaceViewModel.swift
//  PacerRun
//
//  ViewModel for PaceGauge on Apple Watch.
//  Owns its own HKWorkoutSession so this app gets wrist-raise
//  priority — no need to run Apple's Workout app alongside it.
//  Records HR, GPS route, distance, speed, and calories;
//  saves the completed workout to Apple Health.
//  Tracks Running Economy via Cardiac Cost Index (CCI).
//

import Foundation
import Combine
import HealthKit
import CoreLocation

@MainActor
final class WatchPaceViewModel: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var heartRate: Double = 0
    @Published var currentSpeedMPH: Double = 0
    @Published var avgSpeedMPH: Double = 0
    @Published var isActive = false
    @Published var isPaused = false
    @Published var showSummary = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var activeCalories: Double = 0
    @Published var totalDistanceMiles: Double = 0
    @Published var totalStepCount: Double = 0

    // MARK: - Published Session Summary (populated at save time)

    @Published var reSummary: RESummary?
    @Published var weightNormalizedCCI: Double?
    @Published var summaryElapsedSeconds: TimeInterval = 0
    @Published var summaryPaceSecondsPerMile: Double?
    @Published var summaryHRZone: Int = 0
    @Published var summaryAvgStepsPerMin: Double = 0
    @Published var feelingRating: Int = 0          // 1=BAD, 2=NOT BAD, 3=GREAT
    @Published var showFeelingPrompt = false
    @Published var isManualRecording = false

    // MARK: - Gauge Settings (user-adjustable before start)

    @Published var tortoisePace: Double = 3.0   // mph
    @Published var harePace: Double = 6.0       // mph
    @Published var goalPace: Double = 5.0       // mph
    let gaugeMax: Double = 8.0                  // mph

    // MARK: - HR Zone Settings

    @Published var maxHR: Double = 173          // user-adjustable max heart rate

    // MARK: - Workout Config

    /// Set to false for indoor (no GPS). Default true for outdoor GPS speed.
    @Published var isOutdoor: Bool = true

    // MARK: - Audio Splits

    /// Toggle audio pace splits on/off (user-adjustable before start)
    @Published var audioSplitsEnabled: Bool = true

    /// Audio split announcer — speaks pace updates every 3 minutes
    let splitAnnouncer = PaceSplitAnnouncer()

    // MARK: - Running Economy Tracker

    let reTracker = RunningEconomyTracker()

    // MARK: - Private — Workout

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?

    // MARK: - Private — Location

    private let locationManager = CLLocationManager()
    private var startDate: Date?
    private var totalDistanceMeters: Double = 0
    private var lastLocation: CLLocation?
    private var lastGPSUpdate: Date?
    private var staleTimer: Timer?
    private var clockTimer: Timer?
    private var pausedElapsed: TimeInterval = 0
    private var pauseDate: Date?
    private var routeLocations: [CLLocation] = []

    // MARK: - Private — Saved Activity (for trash/delete support)

    private var savedActivityFileURL: URL?
    private var savedActivityDateString: String?
    private var savedWorkout: HKWorkout?

    // MARK: - Private — SPM Tracking (delta-based steps per minute)

    private var previousStepCount: Double = 0
    private var previousStepTime: Date?

    /// All HR samples across the entire session (for session-wide avg).
    private var allSessionHRSamples: [Double] = []

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5

        // Wire the stability-gated interval callback
        reTracker.onStableIntervalComplete = { [weak self] result in
            guard let self else { return }
            self.announceIntervalResult(result)
        }

        // Wire the manual interval callback
        reTracker.onManualIntervalComplete = { [weak self] result in
            guard let self else { return }
            self.announceIntervalResult(result)
        }
    }

    // MARK: - Interval Announcement (driven by RunningEconomyTracker)

    /// Speaks a callout for a completed interval (auto or manual).
    private func announceIntervalResult(_ result: REIntervalResult) {
        let intervalPaceSeconds: Double? = result.avgSpeedMPH > 0.01
            ? 3600.0 / result.avgSpeedMPH : nil
        let hrZone = heartRateZone(bpm: result.avgHR)

        splitAnnouncer.announce(
            intervalPaceSeconds: intervalPaceSeconds,
            intervalHRZone: hrZone,
            intervalAvgStepsPerMin: result.avgSPM,
            intervalCCI: result.cci,
            cciTrend: result.trend,
            targetPaceSeconds: 3600.0 / goalPace
        )
    }

    // MARK: - Manual Interval Toggle

    /// Called when the user taps the INTERVAL button on the watch face.
    func toggleManualInterval() {
        if reTracker.isManualIntervalActive {
            reTracker.stopManualInterval()
            isManualRecording = false
        } else {
            reTracker.startManualInterval()
            isManualRecording = true
        }
    }

    // MARK: - HR Zone Calculation

    /// Standard 5-zone model based on percentage of maxHR.
    ///   Zone 1: 50–60%  |  Zone 2: 60–70%  |  Zone 3: 70–80%
    ///   Zone 4: 80–90%  |  Zone 5: 90–100%
    private func heartRateZone(bpm: Double) -> Int {
        guard maxHR > 0 else { return 1 }
        let pct = bpm / maxHR
        switch pct {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.stepCount)
        ]

        let share: Set<HKSampleType> = [
            HKWorkoutType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        do {
            try await healthStore.requestAuthorization(
                toShare: share, read: read)
        } catch {
            print("[WatchPace] HK auth error: \(error)")
        }

        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Start

    func start() {
        guard !isActive else { return }

        startDate = Date()
        isActive = true
        showSummary = false
        showFeelingPrompt = false
        feelingRating = 0

        totalDistanceMeters = 0
        lastLocation = nil
        lastGPSUpdate = nil
        pausedElapsed = 0
        pauseDate = nil
        heartRate = 0
        currentSpeedMPH = 0
        avgSpeedMPH = 0
        elapsedSeconds = 0
        activeCalories = 0
        totalDistanceMiles = 0
        totalStepCount = 0
        routeLocations = []
        previousStepCount = 0
        previousStepTime = nil
        allSessionHRSamples.removeAll()
        isManualRecording = false

        // Reset summary properties
        summaryElapsedSeconds = 0
        summaryPaceSecondsPerMile = nil
        summaryHRZone = 0
        summaryAvgStepsPerMin = 0

        // Reset Running Economy tracker
        reTracker.reset()
        reSummary = nil
        weightNormalizedCCI = nil

        startWorkoutSession()

        if isOutdoor {
            locationManager.startUpdatingLocation()
            staleTimer = Timer.scheduledTimer(
                withTimeInterval: 6.0, repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkStaleGPS() }
            }
        }

        startClockTimer()

        // Start audio splits
        splitAnnouncer.isEnabled = audioSplitsEnabled
        splitAnnouncer.start()
    }

    // MARK: - Workout Session (owns the session → wrist-raise priority)

    private func startWorkoutSession() {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = isOutdoor ? .outdoor : .indoor

        do {
            let ws = try HKWorkoutSession(
                healthStore: healthStore, configuration: config)
            ws.delegate = self

            let wb = ws.associatedWorkoutBuilder()
            wb.delegate = self
            wb.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config)

            session = ws
            builder = wb

            // Explicitly enable step count collection on the data source
            // (HR, calories, and distance are collected by default for
            // a .running workout, but step count requires opt-in)
            if let ds = wb.dataSource {
                let stepType = HKQuantityType(.stepCount)
                ds.enableCollection(for: stepType, predicate: nil)
            }

            // Start the session — this makes us the frontmost workout app
            ws.startActivity(with: Date())

            Task {
                do {
                    try await wb.beginCollection(at: Date())
                } catch {
                    print("[WatchPace] Builder begin error: \(error)")
                }
            }

            // Route builder for GPS track (outdoor only)
            if isOutdoor {
                routeBuilder = HKWorkoutRouteBuilder(
                    healthStore: healthStore, device: nil)
            }

        } catch {
            print("[WatchPace] Session start error: \(error)")
        }
    }

    // MARK: - Pause (STOP button pressed)

    func pause() {
        session?.pause()

        staleTimer?.invalidate()
        staleTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        locationManager.stopUpdatingLocation()
        pauseDate = Date()
        currentSpeedMPH = 0
        isPaused = true

        // Pause audio splits and stability gate
        splitAnnouncer.pause()
        reTracker.pause()
    }

    // MARK: - Resume

    func resume() {
        session?.resume()

        // Accumulate paused time so avg speed stays accurate
        if let pd = pauseDate {
            pausedElapsed += Date().timeIntervalSince(pd)
            pauseDate = nil
        }
        lastLocation = nil   // discard stale location
        lastGPSUpdate = nil

        if isOutdoor {
            locationManager.startUpdatingLocation()
            staleTimer = Timer.scheduledTimer(
                withTimeInterval: 6.0, repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkStaleGPS() }
            }
        }

        startClockTimer()
        isPaused = false

        // Resume audio splits and stability gate
        splitAnnouncer.isEnabled = audioSplitsEnabled
        splitAnnouncer.resume()
        reTracker.resume()
    }

    // MARK: - Feeling Prompt (shown before save)

    /// Called when the user taps END — shows the feeling prompt
    /// instead of immediately saving.
    func promptFeeling() {
        isPaused = false
        showFeelingPrompt = true
    }

    // MARK: - Save (end workout, write to Apple Health, show summary)

    /// Called after the user selects a feeling rating.
    func save(withRating rating: Int) {
        feelingRating = rating
        showFeelingPrompt = false
        // Accumulate any remaining paused time
        if let pd = pauseDate {
            pausedElapsed += Date().timeIntervalSince(pd)
            pauseDate = nil
        }

        staleTimer?.invalidate()
        staleTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        locationManager.stopUpdatingLocation()

        // ── Compute session-wide summary stats ──

        summaryElapsedSeconds = elapsedSeconds

        // Overall pace (seconds per mile) = total elapsed ÷ total miles
        if totalDistanceMiles > 0.01 {
            summaryPaceSecondsPerMile = elapsedSeconds / totalDistanceMiles
        } else {
            summaryPaceSecondsPerMile = nil
        }

        // Overall average HR → zone
        let overallAvgHR: Double
        if !allSessionHRSamples.isEmpty {
            overallAvgHR = allSessionHRSamples.reduce(0, +)
                / Double(allSessionHRSamples.count)
        } else {
            overallAvgHR = heartRate
        }
        summaryHRZone = heartRateZone(bpm: overallAvgHR)

        // Overall average steps per minute
        let totalMinutes = elapsedSeconds / 60.0
        if totalMinutes > 0 {
            summaryAvgStepsPerMin = totalStepCount / totalMinutes
        } else {
            summaryAvgStepsPerMin = 0
        }

        // ── Build the RE summary first so we can include overall CCI in audio ──
        var summaryOverallCCI: Double? = nil
        if let summary = reTracker.buildSummary() {
            reSummary = summary
            weightNormalizedCCI = reTracker.weightNormalizedCCI(summary.overallCCI)
            summaryOverallCCI = summary.overallCCI
        }

        // ── Speak the end-of-workout summary before stopping the announcer ──
        splitAnnouncer.announceSummary(
            elapsedSeconds: summaryElapsedSeconds,
            overallPaceSeconds: summaryPaceSecondsPerMile,
            overallHRZone: summaryHRZone,
            overallAvgStepsPerMin: summaryAvgStepsPerMin,
            overallCCI: summaryOverallCCI
        )

        // No timer to stop — the announcer is now event-driven.
        // Speech for the summary announcement will play to completion.

        // Save the running activity file to the app's documents directory
        saveActivityFile()

        // Finish workout async — keep session alive until save completes
        Task {
            await finishAndSaveWorkout()
        }
    }

    private func finishAndSaveWorkout() async {
        guard let builder = builder else {
            isActive = false
            isPaused = false
            showSummary = true
            return
        }

        do {
            try await builder.endCollection(at: Date())
            let workout = try await builder.finishWorkout()

            // Keep a reference so trashActivity() can delete it
            savedWorkout = workout

            // Attach the GPS route to the saved workout
            if let routeBuilder = routeBuilder,
               !routeLocations.isEmpty,
               let workout = workout {
                try await routeBuilder.finishRoute(
                    with: workout, metadata: nil)
            }

            print("[WatchPace] Workout saved to Apple Health")
        } catch {
            print("[WatchPace] Save error: \(error)")
        }

        // End session AFTER workout is saved (keeps app alive during save)
        session?.end()

        // Clean up
        session = nil
        self.builder = nil
        routeBuilder = nil

        isActive = false
        isPaused = false
        showSummary = true
    }

    // MARK: - Activity File Persistence

    /// Saves a JSON activity file to the app's documents directory.
    /// File name: "run_YYYY-MM-dd_HHmmss.json"
    private func saveActivityFile() {
        let timestamp = PacerFormatters.fileTimestamp.string(from: startDate ?? Date())
        let fileName = "run_\(timestamp).json"

        // Format pace as "M:SS" string for the file
        let paceString: String
        if let ps = summaryPaceSecondsPerMile, ps.isFinite, ps > 0 {
            let rounded = Int(ps.rounded())
            let paceMin = rounded / 60
            let paceSec = rounded % 60
            paceString = String(format: "%d:%02d", paceMin, paceSec)
        } else {
            paceString = "N/A"
        }

        // Build the activity dictionary
        let activity: [String: Any] = [
            "date": PacerFormatters.iso8601.string(from: startDate ?? Date()),
            "elapsedSeconds": summaryElapsedSeconds,
            "elapsedFormatted": elapsedFormatted,
            "distanceMiles": round(totalDistanceMiles * 100) / 100,
            "paceSecondsPerMile": summaryPaceSecondsPerMile ?? 0,
            "paceFormatted": paceString,
            "avgSpeedMPH": round(avgSpeedMPH * 100) / 100,
            "heartRateZone": summaryHRZone,
            "avgStepsPerMin": round(summaryAvgStepsPerMin),
            "totalSteps": Int(totalStepCount),
            "activeCalories": round(activeCalories * 10) / 10,
            "maxHR": maxHR,
            "goalPaceMPH": goalPace,
            "feelingRating": feelingRating
        ]

        // Add RE data if available
        var fullActivity = activity
        if let re = reSummary {
            // Per-interval SPM-CCI pairs for correlation analysis
            let pairs: [[String: Any]] = re.spmCCIPairs.map { pair in
                [
                    "spm": round(pair.spm * 10) / 10,
                    "cci": round(pair.cci * 10) / 10,
                    "avgSpeedMPH": round(pair.avgSpeedMPH * 100) / 100,
                    "source": pair.source,
                    "isStable": pair.isStable
                ]
            }

            // Time-series snapshots (every ~10 s) for post-run analysis
            let tsSamples: [[String: Any]] = re.timeSeries.map { s in
                [
                    "elapsed": round(s.elapsed * 10) / 10,
                    "spm": round(s.spm * 10) / 10,
                    "hr": round(s.hr * 10) / 10,
                    "speedMPH": round(s.speedMPH * 100) / 100,
                    "isStable": s.isStable
                ]
            }

            fullActivity["runningEconomy"] = [
                "overallCCI": round(re.overallCCI * 10) / 10,
                "bestIntervalCCI": round(re.bestIntervalCCI * 10) / 10,
                "bestIntervalNumber": re.bestIntervalNumber,
                "worstIntervalCCI": round(re.worstIntervalCCI * 10) / 10,
                "worstIntervalNumber": re.worstIntervalNumber,
                "trend": re.finalTrend.rawValue,
                "intervalCount": re.intervalCount,
                "overallAvgSPM": round(re.overallAvgSPM),
                "spmCCIPairs": pairs,
                "timeSeries": tsSamples
            ]
        }
        if let normCCI = weightNormalizedCCI {
            fullActivity["weightNormalizedCCI"] = round(normCCI * 10) / 10
        }

        // Write to documents directory
        guard let docsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            print("[WatchPace] Cannot find documents directory")
            return
        }

        let fileURL = docsURL.appendingPathComponent(fileName)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: fullActivity,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            print("[WatchPace] Activity saved: \(fileURL.lastPathComponent)")
        } catch {
            print("[WatchPace] Activity save error: \(error)")
        }

        // Store references for potential trash/delete
        savedActivityFileURL = fileURL
        savedActivityDateString = fullActivity["date"] as? String

        // Transfer activity data to iPhone for history log
        WatchSessionManager.shared.sendActivityToPhone(fullActivity)
    }

    func dismissSummary() {
        // "Save" path — data is already persisted; just close the summary.
        savedActivityFileURL = nil
        savedActivityDateString = nil
        savedWorkout = nil
        showSummary = false
    }

    /// Deletes the activity from the watch JSON file, iPhone run history,
    /// and Apple Health.  Called when the user confirms Trash.
    func trashActivity() {
        // 1. Delete local JSON file on the watch
        if let fileURL = savedActivityFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            print("[WatchPace] Trashed local file: \(fileURL.lastPathComponent)")
        }

        // 2. Tell iPhone to delete the matching run
        if let dateString = savedActivityDateString {
            WatchSessionManager.shared.sendDeleteToPhone(dateString: dateString)
        }

        // 3. Delete the saved workout from Apple Health
        if let workout = savedWorkout {
            healthStore.delete(workout) { success, error in
                if success {
                    print("[WatchPace] Deleted workout from Apple Health")
                } else if let error = error {
                    print("[WatchPace] Health delete error: \(error)")
                }
            }
        }

        // Clean up references and close the summary
        savedActivityFileURL = nil
        savedActivityDateString = nil
        savedWorkout = nil
        showSummary = false
    }

    // MARK: - Formatted Elapsed Time

    var elapsedFormatted: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private func startClockTimer() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickClock() }
        }
    }

    private func tickClock() {
        guard let start = startDate else { return }
        elapsedSeconds = Date().timeIntervalSince(start) - pausedElapsed
    }

    // MARK: - Stale GPS Check

    private func checkStaleGPS() {
        guard let last = lastGPSUpdate else { return }
        if Date().timeIntervalSince(last) > 3.0 {
            currentSpeedMPH = 0
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchPaceViewModel: HKWorkoutSessionDelegate {

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // State changes handled by pause()/resume()/save()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Session error: \(error)")
        self.save(withRating: 0)
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchPaceViewModel: HKLiveWorkoutBuilderDelegate {

    func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {
        // Pause/resume markers collected automatically
    }

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        for type in collectedTypes {
            guard let qType = type as? HKQuantityType else { continue }

            // Heart rate — from the workout builder (no separate query needed)
            if qType == HKQuantityType(.heartRate) {
                let stats = workoutBuilder.statistics(for: qType)
                let unit = HKUnit.count().unitDivided(by: .minute())
                if let bpm = stats?.mostRecentQuantity()?
                    .doubleValue(for: unit) {
                    self.heartRate = bpm
                    // Collect for session-wide averaging
                    self.allSessionHRSamples.append(bpm)
                    // Feed to RE tracker
                    self.reTracker.addHRSample(bpm)
                }
            }

            // Active calories
            if qType == HKQuantityType(.activeEnergyBurned) {
                let stats = workoutBuilder.statistics(for: qType)
                let unit = HKUnit.kilocalorie()
                if let kcal = stats?.sumQuantity()?
                    .doubleValue(for: unit) {
                    self.activeCalories = kcal
                }
            }

            // Step count — cumulative from workout builder
            if qType == HKQuantityType(.stepCount) {
                let stats = workoutBuilder.statistics(for: qType)
                let unit = HKUnit.count()
                if let steps = stats?.sumQuantity()?
                    .doubleValue(for: unit) {

                    // Compute delta-based SPM and feed to RE tracker
                    if let prevTime = self.previousStepTime,
                       steps > self.previousStepCount {
                        let deltaSteps = steps - self.previousStepCount
                        let deltaSeconds = Date()
                            .timeIntervalSince(prevTime)
                        if deltaSeconds > 1.0 {
                            let spm = (deltaSteps / deltaSeconds) * 60.0
                            if spm > 50 && spm < 250 { // sanity bounds
                                self.reTracker.addSPMSample(spm)
                            }
                        }
                    }
                    self.previousStepCount = steps
                    self.previousStepTime = Date()

                    self.totalStepCount = steps
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchPaceViewModel: CLLocationManagerDelegate {

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last,
              loc.horizontalAccuracy >= 0,
              loc.horizontalAccuracy < 30 else { return }

        lastGPSUpdate = Date()

        let speedMS = max(0, loc.speed)
        currentSpeedMPH = speedMS * 2.23694

        // Feed to RE tracker (stability gate handles interval averaging)
        reTracker.addSpeedSample(currentSpeedMPH)

        if let last = lastLocation {
            let delta = loc.distance(from: last)
            if delta < 100 {
                totalDistanceMeters += delta
            }
        }
        lastLocation = loc

        // Update published distance in miles
        totalDistanceMiles = totalDistanceMeters / 1609.344

        if let start = startDate {
            let elapsed = Date().timeIntervalSince(start)
                - pausedElapsed
            if elapsed > 0 {
                avgSpeedMPH =
                    (totalDistanceMeters / elapsed) * 2.23694
            }
        }

        // Feed location to route builder for Apple Health
        routeLocations.append(loc)
        routeBuilder?.insertRouteData([loc]) { _, error in
            if let error {
                print("[WatchPace] Route insert error: \(error)")
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Location error: \(error)")
    }
}
