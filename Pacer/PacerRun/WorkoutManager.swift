//
//  WorkoutManager.swift
//  PacerRun
//
//  Manages HKWorkoutSession on Apple Watch to stream live HR
//  to the iPhone via WatchConnectivity.
//

import Foundation
import Combine
import HealthKit
import WatchConnectivity

@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var hrQuery: HKAnchoredObjectQuery?

    @Published var currentHR: Double = 0
    @Published var isActive = false

    override private init() {
        super.init()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate)
        ]
        let shareTypes: Set<HKSampleType> = [
            HKWorkoutType.workoutType()
        ]
        do {
            try await healthStore.requestAuthorization(
                toShare: shareTypes, read: readTypes
            )
        } catch {
            print("Watch HealthKit auth error: \(error)")
        }
    }

    // MARK: - Workout Session

    func startWorkout() {
        guard session == nil else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        do {
            let ws = try HKWorkoutSession(
                healthStore: healthStore, configuration: config
            )
            ws.delegate = self
            ws.startActivity(with: Date())
            session = ws
            isActive = true
            startHeartRateQuery()
        } catch {
            print("Failed to start workout: \(error)")
        }
    }

    func stopWorkout() {
        if let q = hrQuery {
            healthStore.stop(q)
            hrQuery = nil
        }
        session?.end()
        session = nil
        isActive = false
        currentHR = 0
    }

    // MARK: - HR Query

    private func startHeartRateQuery() {
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(
            withStart: Date(), end: nil, options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.processSamples(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.processSamples(samples)
        }

        hrQuery = query
        healthStore.execute(query)
    }

    nonisolated private func processSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample],
              let latest = quantitySamples.last else { return }

        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let hr = latest.quantity.doubleValue(for: unit)
        let date = latest.endDate

        // Update Watch UI
        Task { @MainActor [weak self] in
            self?.currentHR = hr
        }

        // Send to iPhone via WatchConnectivity
        guard WCSession.default.isReachable else { return }
        let message: [String: Any] = [
            "type": "heartRate",
            "hr": hr,
            "date": date.timeIntervalSince1970
        ]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            print("WC send error: \(error.localizedDescription)")
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // No action needed — session just needs to be running
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("Workout session error: \(error)")
        Task { @MainActor [weak self] in
            self?.stopWorkout()
        }
    }
}
