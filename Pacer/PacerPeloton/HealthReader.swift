import Foundation
import HealthKit

/// Reads live heart rate and active calories from Apple Health.
///
/// Uses three layers to get Watch data reliably:
/// 1. HKObserverQuery — registers interest so HealthKit syncs from the Watch
/// 2. enableBackgroundDelivery — tells HealthKit to deliver updates frequently
/// 3. Polling every 5s via GCD timer — fallback that doesn't depend on RunLoop
nonisolated final class HealthReader: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    private let store = HKHealthStore()
    private var observerQueries: [HKQuery] = []
    private var anchoredHRQuery: HKAnchoredObjectQuery?
    private var pollTimer: DispatchSourceTimer?
    private var startDate: Date?
    private var lastHRDate: Date?
    private var processedEnergySamples: Set<String> = []
    private var workoutSession: HKWorkoutSession?

    var onHeartRate: (@Sendable (Double, Date) -> Void)?
    var onEnergy: (@Sendable (Double, Date) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    override init() {
        super.init()
    }

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.restingHeartRate),
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
            HKWorkoutType.workoutType()
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)

        // Tell HealthKit we want frequent delivery — encourages Watch sync
        store.enableBackgroundDelivery(
            for: HKQuantityType(.heartRate),
            frequency: .immediate
        ) { _, error in
            if let error = error {
                print("BG delivery HR error: \(error.localizedDescription)")
            }
        }
        store.enableBackgroundDelivery(
            for: HKQuantityType(.activeEnergyBurned),
            frequency: .immediate
        ) { _, error in
            if let error = error {
                print("BG delivery energy error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Profile reads (characteristic types — no query needed)

    /// Read the user's age from their date of birth in Apple Health.
    /// Returns nil if DOB is not set or access was denied.
    func readAge() -> Int? {
        do {
            let dob = try store.dateOfBirthComponents()
            guard let dobDate = Calendar.current.date(from: dob) else {
                return nil
            }
            let age = Calendar.current.dateComponents(
                [.year], from: dobDate, to: Date()
            ).year
            return age
        } catch {
            return nil
        }
    }

    /// Read the user's biological sex from Apple Health.
    /// Returns raw value: 1 = male, 2 = female, 3 = other. Nil if not set.
    func readBiologicalSex() -> Int? {
        do {
            let sex = try store.biologicalSex().biologicalSex
            switch sex {
            case .male:   return 1
            case .female: return 2
            case .other:  return 3
            default:      return nil  // .notSet
            }
        } catch {
            return nil
        }
    }

    // MARK: - Workout history for auto ghost pace

    /// Query Apple Health for workouts in the last 42 days and calculate
    /// the average climbing pace (ft/min) using calorie-based conversion.
    /// Returns nil if no workouts found or HealthKit is unavailable.
    func averagePaceLast42Days(bodyMassKg: Double = 81.6) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -42, to: Date()) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        // Fetch workouts from the last 42 days
        let workouts: [HKWorkout]? = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sortByDate]
            ) { _, samples, error in
                if let error = error {
                    print("Auto ghost workout query error: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: samples as? [HKWorkout])
            }
            store.execute(query)
        }

        guard let workouts = workouts, !workouts.isEmpty else { return nil }

        // Calculate average pace across all workouts
        // Use active calories and duration to derive ft/min
        var totalFeet: Double = 0
        var totalMinutes: Double = 0

        for workout in workouts {
            let kcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie()) ?? 0

            let durationMin = workout.duration / 60.0
            guard durationMin > 0 else { continue }

            if kcal > 0 {
                // Convert calories to feet using ClimbMath
                let feet = ClimbMath.feet(kcal: kcal, massKg: bodyMassKg)
                totalFeet += feet
                totalMinutes += durationMin
            }
        }

        guard totalMinutes > 0, totalFeet > 0 else { return nil }
        return totalFeet / totalMinutes
    }

    /// Query Apple Health for the single best climbing pace (ft/min) from
    /// workouts in the last 42 days. Used as the Rabbit ghost pace.
    /// Returns nil if no workouts found or HealthKit is unavailable.
    func bestPaceLast42Days(bodyMassKg: Double = 81.6) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -42, to: Date()) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        let workouts: [HKWorkout]? = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sortByDate]
            ) { _, samples, error in
                if let error = error {
                    print("Best pace workout query error: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: samples as? [HKWorkout])
            }
            store.execute(query)
        }

        guard let workouts = workouts, !workouts.isEmpty else { return nil }

        var bestPace: Double = 0

        for workout in workouts {
            let kcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie()) ?? 0

            let durationMin = workout.duration / 60.0
            guard durationMin > 0, kcal > 0 else { continue }

            let feet = ClimbMath.feet(kcal: kcal, massKg: bodyMassKg)
            let pace = feet / durationMin
            if pace > bestPace { bestPace = pace }
        }

        return bestPace > 0 ? bestPace : nil
    }

    // MARK: - Live monitoring

    func start(from date: Date) {
        stop()
        // Look back 60s to catch recently-synced Watch samples
        startDate = date.addingTimeInterval(-60)
        lastHRDate = nil
        processedEnergySamples = []

        // 1. Observer queries — register interest so HealthKit pulls from Watch
        let hrObserver = HKObserverQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            if let error = error {
                self?.onError?("HR observer error: \(error.localizedDescription)")
            }
            self?.pollHeartRate()
            completionHandler()
        }

        let energyObserver = HKObserverQuery(
            sampleType: HKQuantityType(.activeEnergyBurned),
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            if let error = error {
                self?.onError?("Energy observer error: \(error.localizedDescription)")
            }
            self?.pollEnergy()
            completionHandler()
        }

        observerQueries = [hrObserver, energyObserver]
        observerQueries.forEach { store.execute($0) }

        // 2. Anchored query for HR — push-based, fires when new samples land
        let hrType = HKQuantityType(.heartRate)
        let hrPredicate = HKQuery.predicateForSamples(
            withStart: date, end: nil, options: .strictStartDate
        )
        let anchored = HKAnchoredObjectQuery(
            type: hrType,
            predicate: hrPredicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, error in
            if let error = error {
                self?.onError?("Anchored HR error: \(error.localizedDescription)")
                return
            }
            self?.handleHRSamples(samples)
        }
        anchored.updateHandler = { [weak self] _, samples, _, _, error in
            if let error = error {
                self?.onError?("Anchored HR update error: \(error.localizedDescription)")
                return
            }
            self?.handleHRSamples(samples)
        }
        anchoredHRQuery = anchored
        store.execute(anchored)

        // 3. GCD timer polls every 5s as a reliable fallback
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.pollHeartRate()
            self?.pollEnergy()
        }
        timer.resume()
        pollTimer = timer

        // 3. Immediate first poll
        pollHeartRate()
        pollEnergy()

        // 4. Start a mirrored workout session so the Watch streams HR
        //    at workout frequency (~5s) through HealthKit — no companion
        //    app needed on the Watch.
        startReadinessSession()
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        if let aq = anchoredHRQuery {
            store.stop(aq)
            anchoredHRQuery = nil
        }
        observerQueries.forEach { store.stop($0) }
        observerQueries.removeAll()
        stopReadinessSession()
    }

    // MARK: - Direct HR fetch (no time filter — gets whatever is newest)

    /// Fetch the single most recent HR sample in HealthKit, regardless of
    /// when it was recorded. This always returns something if the Watch has
    /// ever synced HR data, even if the sample is a few minutes old.
    func fetchLatestHR(completion: @escaping @Sendable (Double?, Date?) -> Void) {
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate, ascending: false
        )
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortByDate]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil, nil)
                return
            }
            let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
            completion(sample.quantity.doubleValue(for: unit), sample.endDate)
        }
        store.execute(query)
    }

    /// Fetch every heart-rate sample recorded between two times, oldest first.
    /// Used by the Readiness Check to sort readings into phases by the time
    /// they were actually measured — even if the Watch synced them later.
    func fetchHRSamples(from start: Date, to end: Date) async -> [(bpm: Double, date: Date)] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: []
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: true
        )
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortByDate]
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
                let result = (samples as? [HKQuantitySample] ?? []).map {
                    (bpm: $0.quantity.doubleValue(for: unit), date: $0.startDate)
                }
                cont.resume(returning: result)
            }
            store.execute(query)
        }
    }

    // MARK: - Workout Session (triggers real-time Watch → iPhone HR sync)

    /// Start a lightweight workout session so the Watch streams HR in real time.
    /// Available on iOS 17+ — mirrors to the paired Watch automatically.
    func startReadinessSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if #available(iOS 26.0, *) {
            do {
                let config = HKWorkoutConfiguration()
                config.activityType = .cycling
                config.locationType = .indoor

                let session = try HKWorkoutSession(healthStore: store, configuration: config)
                session.delegate = self
                session.startActivity(with: Date())
                workoutSession = session
            } catch {
                onError?("Could not start readiness HR session: \(error.localizedDescription)")
            }
        }
    }

    /// End the readiness workout session. The workout is discarded (not saved).
    func stopReadinessSession() {
        workoutSession?.end()
        workoutSession = nil
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        // No action needed — session just needs to be running
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didFailWithError error: Error) {
        onError?("Workout session error: \(error.localizedDescription)")
    }

    /// Process HR samples from the anchored query's push delivery.
    private func handleHRSamples(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample],
              !samples.isEmpty else { return }
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        // Find the most recent sample
        var latest: HKQuantitySample?
        for sample in samples {
            if let current = latest {
                if sample.endDate > current.endDate { latest = sample }
            } else {
                latest = sample
            }
        }
        guard let best = latest else { return }
        if let lastDate = lastHRDate, best.endDate <= lastDate { return }
        lastHRDate = best.endDate
        onHeartRate?(best.quantity.doubleValue(for: unit), best.endDate)
    }

    // MARK: - Polling

    /// Check Apple Health immediately for new heart rate and calories.
    /// Call this when the app returns to the foreground (e.g. after the
    /// rider opened the Health app to force a Watch sync).
    func pollNow() {
        pollHeartRate()
        pollEnergy()
    }

    private func pollHeartRate() {
        guard let startDate = startDate else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate, end: nil, options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate, ascending: false
        )
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortByDate]
        ) { [weak self] _, samples, error in
            if let error = error {
                self?.onError?("HR poll error: \(error.localizedDescription)")
                return
            }
            guard let sample = samples?.first as? HKQuantitySample else { return }
            if let lastDate = self?.lastHRDate, sample.endDate <= lastDate { return }
            self?.lastHRDate = sample.endDate
            let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
            self?.onHeartRate?(
                sample.quantity.doubleValue(for: unit), sample.endDate
            )
        }
        store.execute(query)
    }

    private func pollEnergy() {
        guard let startDate = startDate else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate, end: nil, options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate, ascending: false
        )
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.activeEnergyBurned),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortByDate]
        ) { [weak self] _, samples, error in
            if let error = error {
                self?.onError?("Energy poll error: \(error.localizedDescription)")
                return
            }
            guard let samples = samples as? [HKQuantitySample],
                  !samples.isEmpty else { return }
            let unit = HKUnit.kilocalorie()
            // Deliver each new sample with its own end date so the ride can
            // ignore calories that were burned while the ride was paused.
            for sample in samples.reversed() {   // oldest first
                let id = sample.uuid.uuidString
                guard self?.processedEnergySamples.contains(id) == false
                else { continue }
                self?.processedEnergySamples.insert(id)
                let kcal = sample.quantity.doubleValue(for: unit)
                if kcal > 0 {
                    self?.onEnergy?(kcal, sample.endDate)
                }
            }
        }
        store.execute(query)
    }
}
