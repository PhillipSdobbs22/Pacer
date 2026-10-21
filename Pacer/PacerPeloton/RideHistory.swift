import Foundation

/// A single elevation sample recorded during a ride.
struct ElevationSample: Codable {
    /// Seconds since ride start.
    let elapsed: TimeInterval
    /// Feet gained at this point.
    let feet: Double
}

/// A sprint marker recorded during a ride.
struct SprintMarker: Codable {
    /// Elevation (feet) where the sprint began.
    let elevationFt: Double
    /// Elapsed time (seconds) when sprint started.
    let elapsedStart: TimeInterval
    /// Duration of the sprint in seconds (typically 20).
    let duration: TimeInterval
}

/// A rest marker recorded during a ride.
struct RestMarker: Codable {
    /// Elevation (feet) where rest began.
    let elevationFt: Double
    /// Elapsed time (seconds) when rest started.
    let elapsedStart: TimeInterval
    /// Duration of rest in seconds.
    let duration: TimeInterval
}

/// A completed ride stored on disk.
struct RideRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let mountainName: String
    let mountainGainFt: Double
    /// Total ride duration in seconds.
    let duration: TimeInterval
    /// Total active kcal burned.
    let activeKcal: Double
    /// Peak elevation reached.
    let peakFeet: Double
    /// Elevation samples taken every ~5 seconds.
    let samples: [ElevationSample]
    /// User-chosen name for this ride (optional).
    var label: String?
    /// Rate of Perceived Effort (0–4). nil for legacy rides recorded before RPE was added.
    var rpe: Int?
    /// How the rider felt: "💩" (tired), "😊" (good energy), "💪" (strong). nil for legacy rides.
    var feeling: String?
    /// Sprint markers recorded during the ride.
    var sprintMarkers: [SprintMarker]?
    /// Rest markers recorded during the ride.
    var restMarkers: [RestMarker]?
    /// HealthKit workout UUID link — ties this record to the Apple Health workout
    /// so pace/calories/duration can be pulled from HealthKit instead of stored here.
    var healthKitWorkoutUUID: String?

    /// Average climbing rate in feet per minute.
    var avgFeetPerMin: Double {
        guard duration > 0 else { return 0 }
        return peakFeet / (duration / 60.0)
    }
}

/// Persists ride records as JSON in the app's Documents directory.
final class RideStore {
    static let shared = RideStore()

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ride_history.json")
    }()

    private(set) var rides: [RideRecord] = []

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RideRecord].self, from: data) else {
            rides = []
            return
        }
        rides = decoded.sorted { $0.date > $1.date }
    }

    func save(_ record: RideRecord) {
        rides.insert(record, at: 0)
        persist()
    }

    func delete(_ id: UUID) {
        rides.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rides) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
