//
//  WatchSessionManager.swift
//  PacerRun
//
//  Manages WCSession on the Watch side. Routes commands from
//  the iPhone (start/stop HR streaming) to WorkoutManager.
//  Sends completed activity records to the iPhone via transferUserInfo.
//

import Foundation
import WatchConnectivity

final class WatchSessionManager: NSObject, @unchecked Sendable {
    static let shared = WatchSessionManager()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Send a completed activity record to the iPhone.
    /// Uses transferUserInfo for guaranteed delivery — queued
    /// even when the iPhone is not immediately reachable.
    func sendActivityToPhone(_ activityData: [String: Any]) {
        guard WCSession.default.activationState == .activated else {
            print("[Watch] WCSession not activated — skipping transfer")
            return
        }
        let payload: [String: Any] = [
            "type": "runActivity",
            "activity": activityData
        ]
        WCSession.default.transferUserInfo(payload)
        print("[Watch] Activity queued for iPhone transfer")
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("Watch WCSession error: \(error)")
        } else {
            print("Watch WCSession active: \(activationState.rawValue)")
        }
    }

    /// Handle commands from the iPhone app.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let command = message["command"] as? String else { return }

        Task { @MainActor in
            switch command {
            case "startHR":
                await WorkoutManager.shared.requestAuthorization()
                WorkoutManager.shared.startWorkout()
            case "stopHR":
                WorkoutManager.shared.stopWorkout()
            default:
                break
            }
        }
    }
}
