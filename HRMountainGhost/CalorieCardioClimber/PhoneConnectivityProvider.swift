//
//  PhoneConnectivityProvider.swift
//  CalorieCardioClimber
//
//  Receives live heart rate data and completed activity records
//  from the Apple Watch via WatchConnectivity.
//

import Foundation
import WatchConnectivity
import Combine

@MainActor
final class PhoneConnectivityProvider: NSObject, ObservableObject {
    static let shared = PhoneConnectivityProvider()

    @Published var latestHR: Double = 0
    @Published var latestDate: Date?
    @Published var isWatchReachable = false

    override private init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Ask the Watch to start streaming HR.
    func requestStartHR() {
        guard WCSession.default.isReachable else {
            print("Phone: Watch not reachable")
            return
        }
        WCSession.default.sendMessage(
            ["command": "startHR"],
            replyHandler: nil
        ) { error in
            print("Phone sendMessage error: \(error.localizedDescription)")
        }
    }

    /// Ask the Watch to stop streaming HR.
    func requestStopHR() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["command": "stopHR"],
            replyHandler: nil
        ) { error in
            print("Phone sendMessage error: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneConnectivityProvider: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("Phone WCSession error: \(error)")
        } else {
            print("Phone WCSession active: \(activationState.rawValue)")
        }
    }

    // iOS-only delegate methods
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after switching watches
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            PhoneConnectivityProvider.shared.isWatchReachable = reachable
        }
    }

    /// Receive HR messages from the Watch.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let type = message["type"] as? String,
              type == "heartRate",
              let hr = message["hr"] as? Double,
              let timestamp = message["date"] as? TimeInterval else { return }

        let date = Date(timeIntervalSince1970: timestamp)

        Task { @MainActor in
            PhoneConnectivityProvider.shared.latestHR = hr
            PhoneConnectivityProvider.shared.latestDate = date
        }
    }

    /// Receive completed activity records from the Watch (transferUserInfo).
    /// Guaranteed delivery — queued even when iPhone is not reachable.
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        guard let type = userInfo["type"] as? String,
              type == "runActivity" else { return }

        guard let activityData = userInfo["activity"] as? [String: Any] else {
            print("[Phone] runActivity missing activity payload")
            return
        }

        Task { @MainActor in
            if let record = RunStore.record(from: activityData) {
                RunStore.shared.save(record)
                print("[Phone] Run saved: \(record.date)")
            }
        }
    }
}
