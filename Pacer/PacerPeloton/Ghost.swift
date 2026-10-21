import Foundation
import Combine

/// The psychological role of a ghost rival.
/// Internal raw values stay "rabbit"/"hound" so saved data keeps working;
/// the user-facing names are the Hare and the Tortoise.
enum GhostRole: String, Codable {
    /// Hare — ahead of you, the pace you're chasing (best pace).
    case rabbit
    /// Tortoise — behind you, the pace you must stay ahead of (50% of average).
    case hound

    /// Name shown to the user.
    var displayName: String {
        self == .rabbit ? "Hare" : "Tortoise"
    }

    /// Emoji shown to the user.
    var emoji: String {
        self == .rabbit ? "\u{1F407}" : "\u{1F422}"  // 🐇 / 🐢
    }
}

/// Defines how a ghost climbs the mountain.
enum GhostSource: Codable {
    /// User-configured manual pace (feet per minute).
    case manual(feetPerMin: Double, name: String)
    /// Replay a previous ride's elevation timeline.
    case history(rideId: UUID)
}

/// A ghost rival that advances up the mountain during a ride.
final class Ghost: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let source: GhostSource
    let role: GhostRole
    @Published private(set) var currentFeet: Double = 0

    /// Current pace — mutable so the user can adjust mid-ride.
    @Published var feetPerMin: Double

    // For history ghosts: recorded samples to replay.
    private let samples: [ElevationSample]

    /// Create a manual-pace ghost with a role.
    init(name: String, feetPerMin: Double, role: GhostRole = .rabbit) {
        self.name = name
        self.source = .manual(feetPerMin: feetPerMin, name: name)
        self.feetPerMin = feetPerMin
        self.samples = []
        self.role = role
    }

    /// Create a ghost from a saved ride record.
    init(record: RideRecord, role: GhostRole = .rabbit) {
        self.name = record.label ?? Self.dateLabel(record.date)
        self.source = .history(rideId: record.id)
        self.feetPerMin = record.avgFeetPerMin
        self.samples = record.samples
        self.role = role
    }

    /// Emoji for this ghost's role.
    var emoji: String {
        role.emoji  // 🐇 Hare / 🐢 Tortoise
    }

    /// Advance ghost position based on elapsed seconds.
    func update(elapsed: TimeInterval, mountainGainFt: Double) {
        switch source {
        case .manual:
            currentFeet = min(feetPerMin * (elapsed / 60.0), mountainGainFt)

        case .history:
            if samples.isEmpty {
                // Fallback to average pace if no samples.
                currentFeet = min(feetPerMin * (elapsed / 60.0), mountainGainFt)
            } else {
                currentFeet = min(interpolate(at: elapsed), mountainGainFt)
            }
        }
    }

    func reset() {
        currentFeet = 0
    }

    /// Adjust pace mid-ride by a delta (ft/min).
    func adjustPace(by delta: Double) {
        feetPerMin = max(1, feetPerMin + delta)
    }

    /// Linear interpolation through the recorded samples.
    private func interpolate(at t: TimeInterval) -> Double {
        guard !samples.isEmpty else { return 0 }
        if t <= samples[0].elapsed { return samples[0].feet }
        if t >= samples[samples.count - 1].elapsed { return samples[samples.count - 1].feet }

        for i in 1..<samples.count {
            if t <= samples[i].elapsed {
                let a = samples[i - 1]
                let b = samples[i]
                let frac = (t - a.elapsed) / (b.elapsed - a.elapsed)
                return a.feet + (b.feet - a.feet) * frac
            }
        }
        return samples[samples.count - 1].feet
    }

    private static func dateLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return "Ride \(fmt.string(from: date))"
    }
}
