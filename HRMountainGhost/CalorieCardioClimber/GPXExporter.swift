//
//  GPXExporter.swift
//  CalorieCardioClimber
//
//  Exports a run as a GPX file by querying Apple Health for the
//  workout's GPS route and heart rate samples. The GPX includes
//  Garmin TrackPointExtension data (hr, cad) for compatibility
//  with Strava, Garmin Connect, COROS, and other platforms.
//

import Foundation
import HealthKit
import CoreLocation

enum GPXExporter {

    // MARK: - Public API

    /// Export a GPX file for the given run record.
    /// Queries HealthKit for the matching workout, route, and HR data.
    /// Returns the file URL on success, or throws on failure.
    static func export(run: RunRecord) async throws -> URL {
        let store = HKHealthStore()

        // Request read access for workout routes + HR + step count
        try await requestAccess(store: store)

        // 1. Find the matching HKWorkout by date
        let workout = try await findWorkout(store: store, run: run)

        // 2. Fetch GPS route points
        let locations = try await fetchRouteLocations(store: store, workout: workout)

        // 3. Fetch HR samples during the workout
        let hrSamples = await fetchHRSamples(
            store: store,
            start: workout.startDate,
            end: workout.endDate
        )

        // 4. Build GPX XML
        let gpxString = buildGPX(
            run: run,
            workout: workout,
            locations: locations,
            hrSamples: hrSamples
        )

        // 5. Write to temp file
        let fileName = gpxFileName(for: run)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        try gpxString.write(to: tempURL, atomically: true, encoding: .utf8)

        return tempURL
    }

    // MARK: - HealthKit Authorization

    private static func requestAccess(store: HKHealthStore) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw GPXError.healthKitUnavailable
        }

        let readTypes: Set<HKObjectType> = [
            HKWorkoutType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.stepCount)
        ]

        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - Find Matching Workout

    /// Find the HKWorkout that matches the run's start date (within 5 seconds).
    private static func findWorkout(
        store: HKHealthStore,
        run: RunRecord
    ) async throws -> HKWorkout {
        let startWindow = run.date.addingTimeInterval(-5)
        let endWindow = run.date.addingTimeInterval(5)

        let datePredicate = HKQuery.predicateForSamples(
            withStart: startWindow, end: endWindow, options: []
        )
        let typePredicate = HKQuery.predicateForWorkouts(
            with: .running
        )
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [datePredicate, typePredicate]
        )

        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: compound,
                limit: 1,
                sortDescriptors: [sortByDate]
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard let workout = samples?.first as? HKWorkout else {
                    cont.resume(throwing: GPXError.workoutNotFound)
                    return
                }
                cont.resume(returning: workout)
            }
            store.execute(query)
        }
    }

    // MARK: - Fetch Route Locations

    /// Fetch all GPS points from the workout's route.
    private static func fetchRouteLocations(
        store: HKHealthStore,
        workout: HKWorkout
    ) async throws -> [CLLocation] {

        // First, find the route object attached to the workout
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let routeType = HKSeriesType.workoutRoute()
            let predicate = HKQuery.predicateForObjects(from: workout)

            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                let routeSamples = samples as? [HKWorkoutRoute] ?? []
                cont.resume(returning: routeSamples)
            }
            store.execute(query)
        }

        guard let route = routes.first else {
            throw GPXError.noRouteData
        }

        // Then extract all CLLocation points from the route
        return try await withCheckedThrowingContinuation { cont in
            var allLocations: [CLLocation] = []

            let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                if let locations = locations {
                    allLocations.append(contentsOf: locations)
                }
                if done {
                    cont.resume(returning: allLocations)
                }
            }
            store.execute(routeQuery)
        }
    }

    // MARK: - Fetch HR Samples

    /// Fetch heart rate samples during the workout period.
    private static func fetchHRSamples(
        store: HKHealthStore,
        start: Date,
        end: Date
    ) async -> [(bpm: Double, date: Date)] {
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
                let unit = HKUnit.count().unitDivided(by: .minute())
                let result = (samples as? [HKQuantitySample] ?? []).map {
                    (bpm: $0.quantity.doubleValue(for: unit),
                     date: $0.startDate)
                }
                cont.resume(returning: result)
            }
            store.execute(query)
        }
    }

    // MARK: - Build GPX XML

    private static func buildGPX(
        run: RunRecord,
        workout: HKWorkout,
        locations: [CLLocation],
        hrSamples: [(bpm: Double, date: Date)]
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startTime = iso.string(from: workout.startDate)
        let runName = "Run \(DateFormatter.localizedString(from: run.date, dateStyle: .medium, timeStyle: .short))"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="CalorieCardioClimber"
             version="1.1"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(runName))</name>
            <time>\(startTime)</time>
          </metadata>
          <trk>
            <name>\(escapeXML(runName))</name>
            <type>running</type>
            <trkseg>

        """

        // For each GPS point, find the nearest HR sample by timestamp
        for location in locations {
            let lat = String(format: "%.7f", location.coordinate.latitude)
            let lon = String(format: "%.7f", location.coordinate.longitude)
            let time = iso.string(from: location.timestamp)

            xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"

            // Elevation
            if location.verticalAccuracy >= 0 {
                xml += "        <ele>\(String(format: "%.1f", location.altitude))</ele>\n"
            }

            xml += "        <time>\(time)</time>\n"

            // Find nearest HR sample (within 10 seconds)
            let nearestHR = nearestSample(
                to: location.timestamp, in: hrSamples, maxGap: 10
            )

            // Cadence from the run record's average (per-point cadence
            // isn't stored in HealthKit for Watch SE 1st gen)
            let cadence = run.avgStepsPerMin > 0
                ? Int(run.avgStepsPerMin / 2)  // GPX uses half-cadence (strides/min)
                : nil

            if nearestHR != nil || cadence != nil {
                xml += "        <extensions>\n"
                xml += "          <gpxtpx:TrackPointExtension>\n"
                if let hr = nearestHR {
                    xml += "            <gpxtpx:hr>\(Int(hr.bpm.rounded()))</gpxtpx:hr>\n"
                }
                if let cad = cadence {
                    xml += "            <gpxtpx:cad>\(cad)</gpxtpx:cad>\n"
                }
                xml += "          </gpxtpx:TrackPointExtension>\n"
                xml += "        </extensions>\n"
            }

            xml += "      </trkpt>\n"
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>

        """

        return xml
    }

    // MARK: - Helpers

    /// Find the nearest sample to a given timestamp within maxGap seconds.
    private static func nearestSample(
        to date: Date,
        in samples: [(bpm: Double, date: Date)],
        maxGap: TimeInterval
    ) -> (bpm: Double, date: Date)? {
        var best: (bpm: Double, date: Date)?
        var bestGap: TimeInterval = .greatestFiniteMagnitude

        for sample in samples {
            let gap = abs(sample.date.timeIntervalSince(date))
            if gap < bestGap {
                bestGap = gap
                best = sample
            }
            // Samples are sorted chronologically — if we've passed the
            // target time and gap is growing, stop early.
            if sample.date > date && gap > bestGap { break }
        }

        guard let result = best, bestGap <= maxGap else { return nil }
        return result
    }

    private static func gpxFileName(for run: RunRecord) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "run_\(f.string(from: run.date)).gpx"
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Errors

    enum GPXError: LocalizedError {
        case healthKitUnavailable
        case workoutNotFound
        case noRouteData

        var errorDescription: String? {
            switch self {
            case .healthKitUnavailable:
                return "Apple Health is not available on this device."
            case .workoutNotFound:
                return "Could not find the matching workout in Apple Health. It may not have synced from your Watch yet."
            case .noRouteData:
                return "No GPS route data found for this workout. The run may have been recorded indoors."
            }
        }
    }
}
