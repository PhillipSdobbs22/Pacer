//
//  PacerApp.swift
//  CalorieCardioClimber Watch App
//
//  App entry point for the PaceGauge standalone watch app.
//

import SwiftUI

@main
struct PacerApp: App {
    init() {
        // Activate WatchConnectivity so completed activities
        // transfer to the iPhone via transferUserInfo.
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
