//
//  PacerFormatters.swift
//  Shared
//
//  Cached DateFormatters — allocated once, reused everywhere.
//  DateFormatter init is expensive; creating one per call wastes
//  CPU and memory, especially in computed properties evaluated
//  every SwiftUI body pass.
//

import Foundation

enum PacerFormatters {

    // MARK: - DateFormatters

    /// "Oct 25, 2026, 6:30 AM"
    static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "10/25/26, 6:30 AM"
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// "Oct 25, 2026  6:30 AM" — custom format for run history rows
    static let runHistoryDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy  h:mm a"
        return f
    }()

    /// "2026-10-25_063000" — for file names
    static let fileTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    // MARK: - ISO8601

    /// Standard ISO 8601 (no fractional seconds)
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    /// ISO 8601 with fractional seconds — for GPX export
    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
