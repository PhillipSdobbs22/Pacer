import Foundation
import Combine
import HealthKit

/// Imports historical workouts from Apple Health and converts them
/// into RideRecord objects compatible with the ghost pacer system.
///
/// Any app that syncs to Apple Health (Garmin, Strava, Nike, Coros,
/// RunGap, etc.) will have its workouts available here automatically.
@MainActor
final class HealthHistoryImporter: ObservableObject {
    private let store = HKHealthStore()

    @Published var workouts: [HKWorkout] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Request read access to workouts, active energy, and heart rate.
    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthImportError.healthDataUnavailable
        }
        let readTypes: Set<HKObjectType> = [
            HKWorkoutType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate)
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Fetch recent workouts from HealthKit.
    func fetchWorkouts(limit: Int = 50) async {
        isLoading = true
        errorMessage = nil

        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        do {
            let samples = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: HKWorkoutType.workoutType(),
                    predicate: nil,
                    limit: limit,
                    sortDescriptors: [sortByDate]
                ) { _, samples, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
            workouts = samples.compactMap { $0 as? HKWorkout }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Calorie-based import

    /// Convert a HealthKit workout into a RideRecord by reading its
    /// active-energy samples and converting them to elevation via ClimbMath.
    func importWorkout(
        _ workout: HKWorkout,
        massKg: Double
    ) async -> RideRecord? {
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: true
        )

        do {
            let samples = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: HKQuantityType(.activeEnergyBurned),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [sortByDate]
                ) { _, samples, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }

            let energySamples = samples.compactMap { $0 as? HKQuantitySample }
            let unit = HKUnit.kilocalorie()
            let workoutStart = workout.startDate
            let duration = workout.endDate.timeIntervalSince(workoutStart)

            var cumulativeKcal = 0.0
            var elevationSamples: [ElevationSample] = []

            // Always start at zero.
            elevationSamples.append(ElevationSample(elapsed: 0, feet: 0))

            if !energySamples.isEmpty {
                // Build cumulative calorie timeline from individual samples.
                for sample in energySamples {
                    let kcal = sample.quantity.doubleValue(for: unit)
                    cumulativeKcal += kcal
                    let elapsed = sample.endDate.timeIntervalSince(workoutStart)
                    let feet = ClimbMath.feet(
                        kcal: cumulativeKcal, massKg: massKg
                    )
                    elevationSamples.append(
                        ElevationSample(elapsed: elapsed, feet: feet)
                    )
                }
            } else {
                // Fallback: use the workout's total energy burned as a
                // linear ramp (some sources only store the aggregate).
                let totalEnergy =
                    workout.totalEnergyBurned?.doubleValue(for: unit) ?? 0
                if totalEnergy > 0 {
                    let interval: TimeInterval = 5.0
                    var t: TimeInterval = interval
                    while t < duration {
                        let fraction = t / duration
                        let kcalAtT = totalEnergy * fraction
                        let feet = ClimbMath.feet(
                            kcal: kcalAtT, massKg: massKg
                        )
                        elevationSamples.append(
                            ElevationSample(elapsed: t, feet: feet)
                        )
                        t += interval
                    }
                    let totalFeet = ClimbMath.feet(
                        kcal: totalEnergy, massKg: massKg
                    )
                    elevationSamples.append(
                        ElevationSample(elapsed: duration, feet: totalFeet)
                    )
                    cumulativeKcal = totalEnergy
                }
            }

            let peakFeet = elevationSamples.last?.feet ?? 0

            // Build a label from workout type + source app name.
            let typeName = Self.workoutTypeName(workout.workoutActivityType)
            let sourceName = workout.sourceRevision.source.name
            let label = "\(typeName) \u{2014} \(sourceName)"

            var record = RideRecord(
                id: UUID(),
                date: workout.startDate,
                mountainName: "HealthKit Import",
                mountainGainFt: peakFeet,
                duration: duration,
                activeKcal: cumulativeKcal,
                peakFeet: peakFeet,
                samples: elevationSamples
            )
            record.label = label
            return record

        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - HR Zone-based import

    /// Convert a HealthKit workout into a RideRecord by reading its
    /// heart rate samples and computing elevation via HR zone climb rates.
    /// This produces a fair, activity-agnostic elevation profile.
    func importWorkoutHRZone(
        _ workout: HKWorkout,
        maxHR: Int
    ) async -> RideRecord? {
        guard maxHR > 0 else {
            errorMessage = "Max HR must be set for HR Zone import."
            return nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: true
        )

        do {
            let samples = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: HKQuantityType(.heartRate),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [sortByDate]
                ) { _, samples, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }

            let hrSamples = samples.compactMap { $0 as? HKQuantitySample }
            let hrUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
            let workoutStart = workout.startDate
            let duration = workout.endDate.timeIntervalSince(workoutStart)

            var cumulativeFeet = 0.0
            var elevationSamples: [ElevationSample] = []
            elevationSamples.append(ElevationSample(elapsed: 0, feet: 0))

            if !hrSamples.isEmpty {
                // Walk through HR samples, accumulating zone-based elevation.
                var previousTime = workoutStart

                for sample in hrSamples {
                    let bpm = sample.quantity.doubleValue(for: hrUnit)
                    let sampleTime = sample.endDate
                    let dt = sampleTime.timeIntervalSince(previousTime)

                    // Only accumulate forward-moving time segments.
                    if dt > 0 {
                        let zone = HRZone.zone(
                            hr: bpm, maxHR: Double(maxHR)
                        )
                        cumulativeFeet += zone.feetPerMin * dt / 60.0
                    }

                    let elapsed = sampleTime.timeIntervalSince(workoutStart)
                    elevationSamples.append(
                        ElevationSample(elapsed: elapsed, feet: cumulativeFeet)
                    )
                    previousTime = sampleTime
                }

                // Extend to workout end using the last known zone.
                if let lastSample = hrSamples.last {
                    let lastBpm = lastSample.quantity.doubleValue(for: hrUnit)
                    let remaining = workout.endDate.timeIntervalSince(
                        lastSample.endDate
                    )
                    if remaining > 0 {
                        let zone = HRZone.zone(
                            hr: lastBpm, maxHR: Double(maxHR)
                        )
                        cumulativeFeet += zone.feetPerMin * remaining / 60.0
                        elevationSamples.append(
                            ElevationSample(
                                elapsed: duration, feet: cumulativeFeet
                            )
                        )
                    }
                }
            } else {
                // No HR samples — can't do zone-based import.
                errorMessage = "No heart rate data found for this workout."
                return nil
            }

            let peakFeet = elevationSamples.last?.feet ?? 0

            let typeName = Self.workoutTypeName(workout.workoutActivityType)
            let sourceName = workout.sourceRevision.source.name
            let label = "\(typeName) \u{2014} \(sourceName) (HR Zone)"

            // Use 0 kcal since this is zone-based, not calorie-based.
            var record = RideRecord(
                id: UUID(),
                date: workout.startDate,
                mountainName: "HealthKit Import",
                mountainGainFt: peakFeet,
                duration: duration,
                activeKcal: 0,
                peakFeet: peakFeet,
                samples: elevationSamples
            )
            record.label = label
            return record

        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    /// Human-readable name for common HKWorkoutActivityType values.
    static func workoutTypeName(
        _ type: HKWorkoutActivityType
    ) -> String {
        switch type {
        case .cycling:                          return "Cycling"
        case .running:                          return "Running"
        case .walking:                          return "Walking"
        case .hiking:                           return "Hiking"
        case .swimming:                         return "Swimming"
        case .rowing:                           return "Rowing"
        case .elliptical:                       return "Elliptical"
        case .functionalStrengthTraining:       return "Strength"
        case .traditionalStrengthTraining:      return "Strength"
        case .highIntensityIntervalTraining:    return "HIIT"
        case .yoga:                             return "Yoga"
        case .dance:                            return "Dance"
        case .stairClimbing:                    return "Stair Climbing"
        case .crossTraining:                    return "Cross Training"
        case .mixedCardio:                      return "Mixed Cardio"
        case .coreTraining:                     return "Core Training"
        case .other:                            return "Workout"
        default:                                return "Workout"
        }
    }

    /// Format workout duration for display.
    static func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Format workout date for display.
    static func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    enum HealthImportError: LocalizedError {
        case healthDataUnavailable

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                return "Health data is not available on this device."
            }
        }
    }
}
