//
//  PacerRunApp.swift
//  PacerRun
//
//  App entry point for the PacerRun standalone watch app.
//

import SwiftUI

@main
struct PacerRunApp: App {
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
