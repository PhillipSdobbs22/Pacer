//
//  PaceGaugeView.swift
//  CalorieCardioClimber Watch App
//
//  SwiftUI Canvas-based semicircle PaceGauge for Apple Watch.
//  Maximized to fill the display. Outline arcs with colored fill
//  to current speed. Single solid white avg-pace needle.
//

import SwiftUI

struct PaceGaugeView: View {

    let currentSpeed: Double   // mph
    let avgSpeed: Double       // mph
    let tortoise: Double       // mph
    let hare: Double           // mph
    let gaugeMax: Double       // mph

    // MARK: - Colors

    private let orangeZone  = Color(red: 1.0,  green: 0.48, blue: 0.24)
    private let yellowZone  = Color(red: 1.0,  green: 0.83, blue: 0.0)
    private let greenZone   = Color(red: 0.24, green: 0.86, blue: 0.52)
    private let outlineColor = Color.white.opacity(0.25)

    // MARK: - Body

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let cy = h * 0.85       // center above bottom edge so arc stays visible

            let r  = min(w / 2, cy) * 0.88   // fit within view
            let bandWidth: CGFloat = 16
            let tickLen: CGFloat = 10

            func angle(for mph: Double) -> Angle {
                let clamped = min(max(mph, 0), gaugeMax)
                return .degrees(180.0 + (clamped / gaugeMax) * 180.0)
            }

            func point(at angle: Angle, radius: CGFloat) -> CGPoint {
                let rad = angle.radians
                return CGPoint(
                    x: cx + radius * cos(rad),
                    y: cy + radius * sin(rad)
                )
            }

            // ── 1. Outline arc (full gauge background) ──
            drawArc(ctx: ctx, center: CGPoint(x: cx, y: cy), radius: r,
                    from: angle(for: 0), to: angle(for: gaugeMax),
                    lineWidth: bandWidth, color: outlineColor)

            // ── 2. Filled arc to current speed (zone-colored) ──
            let clampedSpeed = min(max(currentSpeed, 0), gaugeMax)

            if clampedSpeed > 0 {
                // Fill orange portion (0 → min(speed, tortoise))
                let orangeEnd = min(clampedSpeed, tortoise)
                if orangeEnd > 0 {
                    drawArc(ctx: ctx, center: CGPoint(x: cx, y: cy),
                            radius: r,
                            from: angle(for: 0),
                            to: angle(for: orangeEnd),
                            lineWidth: bandWidth, color: orangeZone)
                }

                // Fill yellow portion (tortoise → min(speed, hare))
                if clampedSpeed > tortoise {
                    let yellowEnd = min(clampedSpeed, hare)
                    drawArc(ctx: ctx, center: CGPoint(x: cx, y: cy),
                            radius: r,
                            from: angle(for: tortoise),
                            to: angle(for: yellowEnd),
                            lineWidth: bandWidth, color: yellowZone)
                }

                // Fill green portion (hare → speed)
                if clampedSpeed > hare {
                    drawArc(ctx: ctx, center: CGPoint(x: cx, y: cy),
                            radius: r,
                            from: angle(for: hare),
                            to: angle(for: clampedSpeed),
                            lineWidth: bandWidth, color: greenZone)
                }
            }

            // ── 3. Tick marks at each integer mph ──
            for i in 0...Int(gaugeMax) {
                let a = angle(for: Double(i))
                let outer = point(at: a, radius: r + bandWidth / 2 + 1)
                let inner = point(at: a, radius: r + bandWidth / 2 + 1 - tickLen)
                var tickPath = Path()
                tickPath.move(to: outer)
                tickPath.addLine(to: inner)
                ctx.stroke(tickPath,
                           with: .color(.white.opacity(0.6)),
                           lineWidth: 1.5)
            }

            // ── 3b. Prominent tortoise & hare tick marks ──
            let markerTickLen: CGFloat = tickLen * 2.2
            let markerWidth: CGFloat = 3.0

            // Tortoise marker — orange
            let tortAngle = angle(for: tortoise)
            let tortOuter = point(at: tortAngle,
                                  radius: r + bandWidth / 2 + 1)
            let tortInner = point(at: tortAngle,
                                  radius: r + bandWidth / 2 + 1 - markerTickLen)
            var tortTickPath = Path()
            tortTickPath.move(to: tortOuter)
            tortTickPath.addLine(to: tortInner)
            ctx.stroke(tortTickPath,
                       with: .color(orangeZone),
                       lineWidth: markerWidth)

            // Hare marker — green
            let hareAngle = angle(for: hare)
            let hareOuter = point(at: hareAngle,
                                  radius: r + bandWidth / 2 + 1)
            let hareInner = point(at: hareAngle,
                                  radius: r + bandWidth / 2 + 1 - markerTickLen)
            var hareTickPath = Path()
            hareTickPath.move(to: hareOuter)
            hareTickPath.addLine(to: hareInner)
            ctx.stroke(hareTickPath,
                       with: .color(greenZone),
                       lineWidth: markerWidth)

            // ── 4. Tortoise / Hare emoji markers ──
            let emojiRadius = r + bandWidth / 2 + 16

            let tortoisePos = point(at: angle(for: tortoise),
                                     radius: emojiRadius)
            let tortText = Text("🐢").font(.system(size: 14))
            ctx.draw(ctx.resolve(tortText),
                     at: tortoisePos, anchor: .center)

            let harePos = point(at: angle(for: hare),
                                 radius: emojiRadius)
            let hareText = Text("🐇").font(.system(size: 14))
            ctx.draw(ctx.resolve(hareText),
                     at: harePos, anchor: .center)

            // ── 5. Average pace needle (light gray) with "Avg" label ──
            let needleColor = Color(white: 0.75)   // light gray
            let avgAngle = angle(for: avgSpeed)
            let needleR = r - bandWidth / 2 - 2
            let avgTip = point(at: avgAngle, radius: needleR)

            var avgPath = Path()
            avgPath.move(to: CGPoint(x: cx, y: cy))
            avgPath.addLine(to: avgTip)
            ctx.stroke(avgPath,
                       with: .color(needleColor),
                       style: StrokeStyle(lineWidth: 3,
                                          lineCap: .round))

            // ── 6. Center hub dot ──
            let hubRect = CGRect(x: cx - 5, y: cy - 5,
                                 width: 10, height: 10)
            ctx.fill(Path(ellipseIn: hubRect),
                     with: .color(needleColor))

            // ── 7. "Avg" label — drawn LAST so it's on top of needle ──
            let labelR = needleR * 0.55
            let labelPos = point(at: avgAngle, radius: labelR)
            let avgLabel = Text("Avg")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(needleColor)
            ctx.draw(ctx.resolve(avgLabel),
                     at: labelPos, anchor: .center)
        }
    }

    // MARK: - Arc Drawing Helper

    private func drawArc(
        ctx: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        from: Angle,
        to: Angle,
        lineWidth: CGFloat,
        color: Color
    ) {
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: from, endAngle: to,
                    clockwise: false)
        ctx.stroke(path,
                   with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth,
                                      lineCap: .butt))
    }
}

#Preview {
    PaceGaugeView(
        currentSpeed: 4.8,
        avgSpeed: 3.1,
        tortoise: 2.5,
        hare: 5.0,
        gaugeMax: 8.0
    )
    .frame(width: 180, height: 100)
    .background(.black)
}
