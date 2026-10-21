# Pacer

A native iOS project with two apps: PacerPeloton (iPhone, indoor cycling) converts any heart-rate-monitored activity into a virtual mountain climb. Your Apple Watch supplies live heart rate and active calories, the app estimates vertical gain, and you race "ghosts" built from your own past activities.

## What it does
- **Two climb engines:** Calorie-based (vertical ft from active kcal burned) or HR Zone-based (climb rate scales with heart rate zone)
- **Ghost rivals:** Race against a manual-pace ghost, your best ride, or any saved ride from history
- **Mountain profile:** Live visualization showing your position and ghost positions on the mountain
- **Ghost radar:** Shows the gap between you and each ghost
- **Sprint & rest:** Rider-controlled 20-second sprint intervals and rest periods with markers on the profile
- **Ride history:** Saved rides with RPE (effort rating 0–4) and emoji feeling (💩 tired, 😊 good, 💪 strong)
- **HealthKit integration:** Reads heart rate, active calories, date of birth, and biological sex from Apple Health
- **Max HR formulas:** Tanaka (males) and Gulati (females), auto-selected from HealthKit biological sex

## Requirements
- Mac with Xcode 16 or later
- iPhone running iOS 17 or later (developed on iPhone 13 Pro, iOS 18.6.2)
- Apple Watch paired for heart rate (any model running watchOS 10+)
- Apple ID (free works; installs expire after ~7 days)
- Live heart rate requires a real Apple Watch, not the simulator

## Build and run
1. Clone the repo and open `Pacer.xcodeproj` in Xcode.
2. Set Signing & Capabilities → Team to your own team and update the bundle ID if needed (currently `com.dobbs.PacerPeloton`).
3. Confirm the HealthKit capability is enabled.
4. Turn on Developer Mode on your iPhone.
5. Run on your iPhone and allow Health access when prompted.

## Privacy
Health data (heart rate, calories, workouts) stays on your device. The app has no server and sends nothing off-device. Ride history is saved locally as JSON.

## Project layout
- `Pacer/Pacer/` — iPhone app source (SwiftUI)
  - `ContentView.swift` — All UI (main screen, settings, ride history, health workout picker)
  - `RideViewModel.swift` — Climb engines, ghost management, sprint/rest logic
  - `RideHistory.swift` — Data models and local JSON persistence
  - `Ghost.swift` — Ghost rival with manual and history modes
  - `HealthReader.swift` — HealthKit streaming (heart rate, calories)
  - `HealthHistoryImporter.swift` — Import past HealthKit workouts as ghost data
  - `PacerPelotonApp.swift` — App entry point

## License
Not yet chosen.

