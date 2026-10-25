//
//  PaceSplitAnnouncer.swift
//  PacerRun
//
//  Speaks audio pace callouts when triggered by the
//  RunningEconomyTracker's stability-gated or manual intervals.
//  No longer owns a timer — interval timing is driven by the
//  stability gate in RunningEconomyTracker.
//
//  Uses AVSpeechSynthesizer (available on watchOS 3+).
//
//  Callout structure (segmented with deliberate pauses):
//    1. "Your previous split pace, … {shortPace} …"
//    2. Contextual repeat with zone
//    3. Step rate
//    4. CCI sentence
//    5. Summary recap line
//    6. Target-pace comparison + CCI trend (when target is set)
//
//  Pace and zone are interval-only; elapsed is cumulative.
//

import Foundation
import AVFoundation

@MainActor
final class PaceSplitAnnouncer {

    // MARK: - Configuration

    /// Set to false to silence splits mid-workout.
    var isEnabled: Bool = true

    /// Speech rate multiplier relative to system default.
    /// 1.0 = normal, 0.85 = slightly slower, 0.7 = noticeably slower.
    var speechRateMultiplier: Float = 0.85

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private var lastAnnouncedSplit: Int = 0   // count of splits announced

    // MARK: - Lifecycle

    /// Call when the workout starts.
    func start() {
        lastAnnouncedSplit = 0
        configureAudioSession()
    }

    /// Call when the workout pauses.
    func pause() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Call when the workout resumes after a pause.
    func resume() {
        configureAudioSession()
    }

    /// Call when the workout ends.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        lastAnnouncedSplit = 0
    }

    // MARK: - Announce on Demand (called by the timer)

    /// Builds and speaks a segmented split callout with deliberate pauses,
    /// repetition, and a summary recap.
    ///
    /// Example spoken output (pauses shown as "…"):
    ///   "Your previous split pace, … Nine fifty-four, …
    ///    that's a nine fifty-four average for your previous split pace in …
    ///    Zone 5 … with an average step rate of … 176 steps per minute. …
    ///    A Nine fifty-four, zone 5, 176 is a
    ///     Cardiac Cost Index of … 27. …
    ///    In summary, your previous split was Nine fifty-four, zone 5,
    ///    176, Twenty-seven. …
    ///    You are ahead of target pace and Cardiac Cost is increasing."
    ///
    /// - Parameters:
    ///   - intervalPaceSeconds: Interval pace in total seconds per mile.
    ///   - intervalHRZone: Heart rate zone (1–5) for this interval.
    ///   - intervalAvgStepsPerMin: Average steps per minute this interval.
    ///   - intervalCCI: Cardiac Cost Index for this interval (nil if unavailable).
    ///   - cciTrend: RE trend across intervals (.improving, .steady, .fading, .none).
    ///   - targetPaceSeconds: Target pace in seconds/mile (nil = no target set).
    func announce(
        intervalPaceSeconds: Double?,
        intervalHRZone: Int,
        intervalAvgStepsPerMin: Double,
        intervalCCI: Double?,
        cciTrend: RETrend,
        targetPaceSeconds: Double? = nil
    ) {
        guard isEnabled else { return }

        lastAnnouncedSplit += 1

        let shortPace = shortPaceString(intervalPaceSeconds)
        let spmInt = Int(intervalAvgStepsPerMin.rounded())
        let zone = intervalHRZone

        var segments: [SpeechSegment] = []

        // ── 1. Intro + pace ──
        segments.append(SpeechSegment(
            text: "Your previous split,",
            postDelay: 2.0
        ))
        segments.append(SpeechSegment(
            text: "\(shortPace).",
            postDelay: 2.0
        ))

        // ── 2. Contextual repeat, then zone ──
        segments.append(SpeechSegment(
            text: "That's a \(shortPace) average,",
            postDelay: 2.0
        ))
        segments.append(SpeechSegment(
            text: "Zone \(zone),",
            postDelay: 2.0
        ))

        // ── 3. Step rate ──
        segments.append(SpeechSegment(
            text: "with a cadence of,",
            postDelay: 2.0
        ))
        segments.append(SpeechSegment(
            text: "\(spmInt) steps per minute.",
            postDelay: 2.0
        ))

        // ── 4. CCI sentence (one flowing phrase, pause only before the number) ──
        if let cci = intervalCCI {
            let cciRounded = Int(cci.rounded())
            segments.append(SpeechSegment(
                text: "A \(shortPace), zone \(zone), \(spmInt) is a Cardiac Cost Index of,",
                postDelay: 2.0
            ))
            segments.append(SpeechSegment(
                text: "\(cciRounded).",
                postDelay: 3.0
            ))
        }

        // ── 5. Summary recap (one continuous phrase, no internal pauses) ──
        let cciSummary: String
        if let cci = intervalCCI {
            cciSummary = ", \(Int(cci.rounded()))"
        } else {
            cciSummary = ""
        }
        segments.append(SpeechSegment(
            text: "In summary, your previous interval was \(shortPace), zone \(zone), \(spmInt)\(cciSummary).",
            postDelay: 2.0
        ))

        // ── 6. Target-pace comparison + CCI trend ──
        if let target = targetPaceSeconds, let actual = intervalPaceSeconds,
           actual.isFinite, actual > 0 {
            // Lower pace seconds = faster, so actual < target means ahead
            let comparison = actual <= target
                ? "You are ahead of target pace"
                : "You are behind target pace"

            let trendPhrase: String
            switch cciTrend {
            case .fading:    trendPhrase = "and Cardiac Cost is increasing."
            case .improving: trendPhrase = "and Cardiac Cost is decreasing."
            case .steady:    trendPhrase = "and Cardiac Cost is steady."
            case .none:      trendPhrase = ""
            }

            let combined = trendPhrase.isEmpty
                ? "\(comparison)."
                : "\(comparison) \(trendPhrase)"
            segments.append(SpeechSegment(text: combined, postDelay: 0))

        } else if cciTrend != .none {
            // No target pace set, but we do have a CCI trend
            let trendPhrase: String
            switch cciTrend {
            case .fading:    trendPhrase = "Cardiac Cost is increasing."
            case .improving: trendPhrase = "Cardiac Cost is decreasing."
            case .steady:    trendPhrase = "Cardiac Cost is steady."
            case .none:      trendPhrase = ""
            }
            if !trendPhrase.isEmpty {
                segments.append(SpeechSegment(text: trendPhrase, postDelay: 0))
            }
        }

        speakSegments(segments)
    }

    // MARK: - End-of-Workout Summary Announcement

    /// Speaks the session-wide summary when the workout ends.
    /// Uses the same segmented style with pauses.
    /// - Parameters:
    ///   - elapsedSeconds: Total workout elapsed time (excluding pauses).
    ///   - overallPaceSeconds: Overall pace in total seconds per mile.
    ///   - overallHRZone: Heart rate zone (1–5) based on session-wide avg HR.
    ///   - overallAvgStepsPerMin: Average steps per minute across the workout.
    ///   - overallCCI: Session-wide CCI (nil if unavailable).
    func announceSummary(
        elapsedSeconds: TimeInterval,
        overallPaceSeconds: Double?,
        overallHRZone: Int,
        overallAvgStepsPerMin: Double,
        overallCCI: Double? = nil
    ) {
        // 1. Total elapsed time
        let totalMin = Int(elapsedSeconds) / 60
        let totalSec = Int(elapsedSeconds) % 60
        let elapsed: String
        if totalMin > 0 && totalSec > 0 {
            elapsed = "\(totalMin) minutes \(totalSec) seconds"
        } else if totalMin > 0 {
            elapsed = "\(totalMin) minutes"
        } else {
            elapsed = "\(totalSec) seconds"
        }

        let shortPace = shortPaceString(overallPaceSeconds)
        let spmInt = Int(overallAvgStepsPerMin.rounded())

        var segments: [SpeechSegment] = []

        segments.append(SpeechSegment(
            text: "Activity complete.",
            postDelay: 2.0
        ))
        segments.append(SpeechSegment(
            text: "\(elapsed),",
            postDelay: 1.0
        ))
        segments.append(SpeechSegment(
            text: "\(shortPace),",
            postDelay: 1.0
        ))
        segments.append(SpeechSegment(
            text: "zone \(overallHRZone),",
            postDelay: 1.0
        ))
        segments.append(SpeechSegment(
            text: "\(spmInt) steps per minute.",
            postDelay: 2.0
        ))

        if let cci = overallCCI {
            segments.append(SpeechSegment(
                text: "Overall Cardiac Cost Index, \(Int(cci.rounded())).",
                postDelay: 0
            ))
        }

        configureAudioSession()
        speakSegments(segments)
    }

    // MARK: - TTS Helpers

    /// A single speech segment with optional pre/post silence.
    private struct SpeechSegment {
        let text: String
        var preDelay: TimeInterval = 0
        var postDelay: TimeInterval = 0
    }

    /// Queues a sequence of speech segments, each with its own pause timing.
    /// AVSpeechSynthesizer plays them in FIFO order.
    private func speakSegments(_ segments: [SpeechSegment]) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        for seg in segments {
            let utterance = AVSpeechUtterance(string: seg.text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice(
                    language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterance.rate  = AVSpeechUtteranceDefaultSpeechRate * speechRateMultiplier
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.preUtteranceDelay  = seg.preDelay
            utterance.postUtteranceDelay = seg.postDelay
            synthesizer.speak(utterance)
        }
    }

    /// Converts pace in seconds/mile to a short spoken form.
    /// 594 → "9 54" (spoken as "nine fifty-four")
    /// 600 → "10 flat"
    /// nil → "no pace"
    private func shortPaceString(_ paceSeconds: Double?) -> String {
        guard let ps = paceSeconds, ps.isFinite, ps > 0 else {
            return "no pace"
        }
        let rounded = Int(ps.rounded())
        let m = rounded / 60
        let s = rounded % 60
        if s > 0 {
            return "\(m) \(String(format: "%02d", s))"
        } else {
            return "\(m) minute mile"
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt)
            try session.setActive(true)
        } catch {
            print("[PaceSplit] Audio session error: \(error)")
        }
    }

}
