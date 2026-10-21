//
//  HRZoneBarView.swift
//  CalorieCardioClimber Watch App
//
//  5-segment heart rate zone bar matching Apple's watchOS workout
//  zone colors.  A white triangular cursor marks the current HR
//  position on the bar.
//

import SwiftUI

struct HRZoneBarView: View {

    let heartRate: Double   // current bpm (0 = no reading)
    let maxHR: Double       // user's active max HR

    // MARK: - Apple watchOS Zone Colors

    private static let zoneColors: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.96),   // Zone 1 — blue
        Color(red: 0.35, green: 0.78, blue: 0.98),   // Zone 2 — cyan
        Color(red: 0.64, green: 0.86, blue: 0.0),    // Zone 3 — green-yellow
        Color(red: 1.0,  green: 0.58, blue: 0.0),    // Zone 4 — orange
        Color(red: 1.0,  green: 0.22, blue: 0.37),   // Zone 5 — pink
    ]

    // MARK: - Zone Calculations

    /// Zone boundaries as fractions of maxHR: [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]
    private let zoneFractions: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Current zone 1-5 (0 if below zone 1 or no reading)
    private var currentZone: Int {
        guard heartRate > 0, maxHR > 0 else { return 0 }
        let pct = heartRate / maxHR
        if pct < 0.60 { return 1 }
        if pct < 0.70 { return 2 }
        if pct < 0.80 { return 3 }
        if pct < 0.90 { return 4 }
        return 5
    }

    /// Upper bpm boundary for the current zone
    private var zoneUpperBPM: Int {
        let idx = min(currentZone, 5)
        if idx <= 0 { return Int(maxHR * 0.60) }
        return Int(maxHR * zoneFractions[idx])
    }

    /// Cursor position as fraction 0…1 across the full bar.
    /// Bar spans from 50% maxHR to 100% maxHR.
    private var cursorFraction: CGFloat {
        guard heartRate > 0, maxHR > 0 else { return 0 }
        let low = maxHR * 0.50
        let range = maxHR - low       // 50% of maxHR
        let fraction = (heartRate - low) / range
        return CGFloat(min(max(fraction, 0), 1))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Zone label
            HStack(spacing: 0) {
                if currentZone > 0 {
                    Text("♥")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    Text(" ZONE \(currentZone)")
                        .font(.system(size: 10, weight: .bold,
                                      design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                if heartRate > 0 {
                    Text("<\(zoneUpperBPM) bpm")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)

            // The 5-segment bar + cursor
            GeometryReader { geo in
                let totalW = geo.size.width
                let barH: CGFloat = 18
                let gap: CGFloat = 2

                ZStack(alignment: .topLeading) {
                    // Segment rectangles
                    HStack(spacing: gap) {
                        ForEach(0..<5, id: \.self) { i in
                            let isActive = (currentZone - 1) == i
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.zoneColors[i]
                                    .opacity(isActive ? 1.0 : 0.30))
                                .frame(height: barH)
                                .overlay(
                                    Group {
                                        if isActive {
                                            Text("♥ ZONE \(i + 1)")
                                                .font(.system(
                                                    size: 8,
                                                    weight: .bold,
                                                    design: .rounded))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                        }
                                    }
                                )
                        }
                    }

                    // Triangular cursor beneath bar
                    if heartRate > 0 {
                        let cursorX = cursorFraction * totalW
                        Triangle()
                            .fill(Color.white)
                            .frame(width: 10, height: 7)
                            .offset(x: cursorX - 5,
                                    y: barH + 1)
                    }
                }
            }
            .frame(height: 28)   // bar 18 + cursor 7 + gap
        }
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))    // top center (point up)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // bottom right
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // bottom left
        p.closeSubpath()
        return p
    }
}

#Preview {
    VStack {
        HRZoneBarView(heartRate: 62, maxHR: 170)
        HRZoneBarView(heartRate: 130, maxHR: 170)
        HRZoneBarView(heartRate: 155, maxHR: 170)
    }
    .padding()
    .background(.black)
}
