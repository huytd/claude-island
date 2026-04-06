//
//  NotchHeaderView.swift
//  ClaudeIsland
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var enableDancing: Bool = false
    var bounceOnly: Bool = false

    @State private var dancePhase: Int = 0
    @State private var dropOffset: CGFloat = 0
    @State private var wobbleAngle: CGFloat = 0
    @State private var isDropping = true

    // Timer for dance animation
    private let danceTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    /// Whether any animation is active (timer guard)
    private var isAnimating: Bool {
        enableDancing || bounceOnly
    }

    init(size: CGFloat = 16, color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), enableDancing: Bool = false, bounceOnly: Bool = false) {
        self.size = size
        self.color = color
        self.enableDancing = enableDancing
        self.bounceOnly = bounceOnly
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Dance transforms
            let bounceY = dropOffset
            let wobble = wobbleAngle

            func makeTransform() -> CGAffineTransform {
                let cx = 33.0  // center of the virtual grid (66/2)
                let cy = 26.0  // center of the virtual grid (52/2)
                // Order matters: last call = first applied to point.
                // So the sequence bottom-up is: T(-cx,-cy) → R → S → T(canvas center + bounce)
                // This rotates around (cx,cy) in virtual space, then scales to canvas coords.
                return CGAffineTransform.identity
                    .translatedBy(x: cx * scale + xOffset, y: cy * scale + bounceY * scale)
                    .scaledBy(x: scale, y: scale)
                    .rotated(by: wobble)
                    .translatedBy(x: -cx, y: -cy)
            }

            let transform = makeTransform()

            // Draw legs behind the body
            let legXPositions: [CGFloat] = [6, 18, 42, 54]
            let legY: CGFloat = 39
            let baseLegHeight: CGFloat = 13

            // Dance leg patterns — 8-phase kick cycle
            let danceLegOffsets: [[CGFloat]] = [
                [ 4, -4,  4, -4],   // 0: kick!
                [ 2, -2,  2, -2],   // 1:
                [ 0,  0,  0,  0],   // 2: feet together
                [-4,  4, -4,  4],   // 3: kick opposite
                [-2,  2, -2,  2],   // 4:
                [ 0,  0,  0,  0],   // 5: together
                [ 3,  3, -3, -3],   // 6: left legs up, right down
                [-3, -3,  3,  3],   // 7: right legs up, left down
            ]

            let currentOffsets = enableDancing ? danceLegOffsets[dancePhase % 8] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in legXPositions.enumerated() {
                let offset = currentOffsets[index]
                let legHeight = baseLegHeight + offset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: legY, width: 6, height: legHeight))
                }.applying(transform)
                context.fill(leg, with: .color(color))
            }

            // Main body
            let crabBody = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(transform)
            context.fill(crabBody, with: .color(color))

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(transform)
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(transform)
            context.fill(rightAntenna, with: .color(color))

            // Eyes with a little dance — eyes shift up slightly on beat
            let eyeBounce: CGFloat = (!isDropping && enableDancing) ? (dancePhase % 2 == 0 ? -2 : 0) : 0
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13.0 + eyeBounce, width: 6.0, height: 6.5))
            }.applying(transform)
            context.fill(leftEye, with: .color(.black))

            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13.0 + eyeBounce, width: 6.0, height: 6.5))
            }.applying(transform)
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .shadow(color: (enableDancing || bounceOnly) ? color.opacity(0.8) : .clear, radius: 4, x: 0, y: 0)
        .onReceive(danceTimer) { _ in
            if isAnimating {
                dancePhase = (dancePhase + 1) % 8

                if isDropping {
                    // Drop-in bounce: above position → impact → settle
                    let dropWave: [CGFloat] = [
                        -30,  // fall from above
                        -18,  // coming down fast
                         -6,  // almost there
                          3,  // impact - overshoot (squish)
                         -1,  // bounce back slightly
                          0,  // settled
                    ]
                    let phase = dancePhase % dropWave.count
                    dropOffset = dropWave[phase]
                    if phase == dropWave.count - 1 {
                        isDropping = false
                    }
                } else {
                    if bounceOnly {
                        // Bounce + stronger wobble
                        let bounceWave: [CGFloat] = [-12, -6, 0, -6]
                        dropOffset = bounceWave[dancePhase % bounceWave.count]
                        let bounceWobbleWave: [CGFloat] = [-0.15, -0.08, 0.05, -0.08]
                        wobbleAngle = bounceWobbleWave[dancePhase % bounceWobbleWave.count]
                    } else {
                        // Settled: continuous wobble
                        let wobbleWave: [CGFloat] = [-0.08, -0.05, 0, 0.05, 0.08, 0.05, 0, -0.05]
                        wobbleAngle = wobbleWave[dancePhase % wobbleWave.count]
                        dropOffset = 0
                    }
                }
            } else {
                // Reset for next drop
                if !isDropping || dropOffset != 0 {
                    dancePhase = 0
                    dropOffset = 0
                    wobbleAngle = 0
                    isDropping = true
                }
            }
        }
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

