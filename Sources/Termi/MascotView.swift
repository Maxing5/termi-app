import SwiftUI

// MARK: - Rig constants
//
// Every proportion of the character lives here. Change a number, `swift build && ./run.sh`,
// see it ~3 seconds later. Nothing else in the app hardcodes geometry.

enum Rig {
    static let bodyW: CGFloat = 72
    static let bodyH: CGFloat = 58
    static let corner: CGFloat = 11
    static let titleBarH: CGFloat = 15
    static let outline: CGFloat = 1.6

    static let eyeR: CGFloat = 4.6
    static let eyeGap: CGFloat = 12       // half-distance between eyes
    static let eyeY: CGFloat = -5         // relative to screen centre

    static let mouthY: CGFloat = 8
    static let mouthW: CGFloat = 15

    static let legSpread: CGFloat = 13
    static let legLen: CGFloat = 13
    static let legW: CGFloat = 4.5
    static let footW: CGFloat = 11

    static let armSeg1 = CGSize(width: 11, height: 9)
    static let armSeg2 = CGSize(width: 8, height: 8)
    static let armW: CGFloat = 4.0

    /// Shell colours — a terminal window: dark screen, lighter chrome, light outline
    /// so the silhouette reads against both light and dark wallpapers.
    static let shell = Color(white: 0.16)
    static let chrome = Color(white: 0.26)
    static let stroke = Color(white: 0.93)

    /// Badge colours. Asking/done match the mascot's own pose colors (Pose.phosphor
    /// for those states) so the top-left badges read as the same signal, not a
    /// separate palette.
    static let askingColor = Color(red: 1.0, green: 0.72, blue: 0.3)
    static let doneColor = Color(red: 0.13, green: 0.58, blue: 0.32)
    static let badgeGap: CGFloat = 18
}

// MARK: - Animation parameters
//
// A pure function of (state, elapsed time). No @State animation machinery, so a state
// change can never leave a half-finished or stuck repeating animation behind.

struct Pose {
    var hopY: CGFloat = 0
    var breathe: CGFloat = 1
    var bobY: CGFloat = 0
    var eyeOpen: CGFloat = 1        // 1 = open, ~0 = blinking
    var eyeScale: CGFloat = 1
    var eyeLookX: CGFloat = 0
    var happyEyes = false           // draw ^ ^ arcs instead of circles
    var mouthCurve: CGFloat = 0.25  // -1 frown … +1 big smile
    var mouthOpen = false           // small "o" for the asking state
    var armAngleL: Double = 0       // degrees; negative raises the arm
    var armAngleR: Double = 0
    var cursorOn = true
    var scrollPhase: CGFloat = 0
    var bubble: String? = nil
    var glow: CGFloat = 0
    var phosphor: Color = Color(red: 0.62, green: 0.72, blue: 0.68)

    static func make(state: MascotDisplayState, t: Double, elapsed: Double) -> Pose {
        var p = Pose()

        // Idle blink on two out-of-phase cycles, so it never feels metronomic.
        func blinking(_ period: Double, _ dur: Double = 0.11) -> Bool {
            t.truncatingRemainder(dividingBy: period) < dur
        }

        switch state {
        case .none:
            break

        case .idle:
            p.breathe = 1 + 0.015 * sin(2 * .pi * t / 2.4)
            p.eyeOpen = (blinking(9.0) || blinking(14.0)) ? 0.08 : 1
            p.cursorOn = t.truncatingRemainder(dividingBy: 2.2) < 1.1
            p.mouthCurve = 0.25
            p.armAngleL = 4
            p.armAngleR = 4

        case .working:
            p.bobY = 1.5 * sin(2 * .pi * t / 1.4)
            p.breathe = 1 + 0.008 * sin(2 * .pi * t / 1.4)
            // Alternating arms: typing, slowed to a calmer pace.
            p.armAngleL = 7 * sin(2 * .pi * t / 0.5)
            p.armAngleR = 7 * sin(2 * .pi * t / 0.5 + .pi)
            p.eyeLookX = 2.2 * sin(2 * .pi * t / 2.6)
            p.eyeOpen = blinking(5.1) ? 0.08 : 1
            p.cursorOn = t.truncatingRemainder(dividingBy: 0.7) < 0.35
            p.mouthCurve = 0.05
            p.scrollPhase = CGFloat(t.truncatingRemainder(dividingBy: 2.4) / 2.4)
            p.glow = 0.5
            p.phosphor = Color(red: 0.45, green: 0.85, blue: 0.95)

        case .asking:
            // Same brief-celebration treatment as `.done` — SessionStore decays this
            // pose back to idle on its own; the orange badge is what actually
            // persists until the question is answered.
            let cycle = 0.55
            let ph = elapsed.truncatingRemainder(dividingBy: cycle) / cycle
            p.hopY = -14 * CGFloat(sin(.pi * ph))
            p.eyeScale = 1.18
            p.eyeOpen = 1
            p.mouthOpen = true
            p.armAngleL = -52
            p.armAngleR = -52
            p.cursorOn = t.truncatingRemainder(dividingBy: 0.5) < 0.25
            p.bubble = "?"
            p.glow = 0.9
            p.phosphor = Color(red: 1.0, green: 0.72, blue: 0.3)

        case .done:
            // Three hops with decaying height, then it settles.
            let cycle = 0.42
            let n = floor(elapsed / cycle)
            let amp: CGFloat = n < 3 ? 16 * pow(0.72, CGFloat(n)) : 0
            let ph = elapsed.truncatingRemainder(dividingBy: cycle) / cycle
            p.hopY = -amp * CGFloat(sin(.pi * ph))
            p.happyEyes = true
            p.mouthCurve = 0.95
            p.armAngleL = -48
            p.armAngleR = -48
            p.cursorOn = true
            p.bubble = "✓"
            p.glow = 0.7
            p.phosphor = Rig.doneColor
        }

        return p
    }
}

/// Plain reference box, not itself observed — see MascotView.freeze.
private final class PoseFreeze {
    var pose: Pose?
}

// MARK: - View

struct MascotView: View {
    @ObservedObject var store: SessionStore
    @State private var stateEnteredAt = Date()

    /// Holds the character's pose still while a resize is in progress (see
    /// MascotSettings.isResizingMascot). A plain class, not @State: this is a
    /// cache mutated during body evaluation, not something that should itself
    /// trigger a re-render — TimelineView's own 30fps tick already does that.
    @State private var freeze = PoseFreeze()

    var body: some View {
        // 30fps is plenty for this character and costs half of a display-linked
        // schedule — this app runs all day.
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let elapsed = ctx.date.timeIntervalSince(stateEnteredAt)
            let livePose = Pose.make(state: store.displayState, t: t, elapsed: elapsed)
            let pose = resolvedPose(live: livePose)

            // Read fresh every tick, same pattern as the badge counts — the character
            // is drawn once at its fixed base size and scaled as a whole here, so
            // resizing never has to touch Rig's own geometry.
            CharacterView(
                pose: pose,
                count: store.sessions.count,
                doneCount: store.doneBadgeCount,
                askingCount: store.askingBadgeCount
            )
            .scaleEffect(MascotSettings.scale)
        }
        // Fills whatever size MascotPanel currently is (it resizes the real window
        // to match the scale), rather than a fixed size — the scaled content is
        // centered in it automatically since scaleEffect scales around its own centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.displayState) {
            // Reset the clock so hops always start from the ground.
            stateEnteredAt = Date()
        }
    }

    /// Resizing and animating at the same time reads as janky — hold the last
    /// live pose steady for the whole gesture, then resume normally the instant
    /// it ends. Plain function rather than inline `if/else` in the TimelineView
    /// closure: that confused @ViewBuilder's control-flow rewriting since the
    /// branches don't produce View content.
    private func resolvedPose(live: Pose) -> Pose {
        guard MascotSettings.isResizingMascot else {
            freeze.pose = nil
            return live
        }
        if freeze.pose == nil { freeze.pose = live }
        return freeze.pose!
    }
}

private struct CharacterView: View {
    let pose: Pose
    let count: Int
    let doneCount: Int
    let askingCount: Int

    var body: some View {
        // Asking always claims the top-left corner when present; done shifts one slot
        // right of it. With no asking, done sits in the corner itself.
        let topLeftX = -(Rig.bodyW / 2 - 1)
        let topY = -(Rig.bodyH / 2) - 1

        ZStack {
            if let bubble = pose.bubble {
                BubbleView(symbol: bubble, tint: pose.phosphor)
                    .offset(y: -(Rig.bodyH / 2 + 30))
            }

            ZStack {
                ArmsView(pose: pose)
                LegsView(pose: pose)
                BodyView(pose: pose)

                if count >= 2 {
                    CountBadgeView(count: count, color: .accentColor)
                        .offset(x: -topLeftX, y: topY)
                }
                if askingCount >= 1 {
                    CountBadgeView(count: askingCount, color: Rig.askingColor)
                        .offset(x: topLeftX, y: topY)
                }
                if doneCount >= 1 {
                    CountBadgeView(count: doneCount, color: Rig.doneColor)
                        .offset(x: topLeftX + (askingCount >= 1 ? Rig.badgeGap : 0), y: topY)
                }
            }
            .scaleEffect(x: 1, y: pose.breathe, anchor: .bottom)
            .offset(y: pose.hopY + pose.bobY)
        }
        .frame(width: kBasePanelSize.width, height: kBasePanelSize.height)
        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
    }
}

// MARK: - Body (the terminal window + face)

private struct BodyView: View {
    let pose: Pose

    var body: some View {
        let screenH = Rig.bodyH - Rig.titleBarH

        ZStack {
            RoundedRectangle(cornerRadius: Rig.corner)
                .fill(Rig.shell)

            VStack(spacing: 0) {
                // Title bar with traffic lights
                ZStack(alignment: .leading) {
                    Rig.chrome
                    HStack(spacing: 4) {
                        dot(Color(red: 1.0, green: 0.37, blue: 0.35))
                        dot(Color(red: 1.0, green: 0.74, blue: 0.28))
                        dot(Color(red: 0.32, green: 0.85, blue: 0.40))
                    }
                    .padding(.leading, 7)
                }
                .frame(height: Rig.titleBarH)

                // Screen
                ZStack {
                    Color.clear
                    if pose.scrollPhase > 0 { ScrollLinesView(phase: pose.scrollPhase) }
                    FaceView(pose: pose)
                    PromptView(pose: pose, screenH: screenH)
                }
                .frame(height: screenH)
            }
            .clipShape(RoundedRectangle(cornerRadius: Rig.corner))

            RoundedRectangle(cornerRadius: Rig.corner)
                .strokeBorder(Rig.stroke, lineWidth: Rig.outline)
        }
        .frame(width: Rig.bodyW, height: Rig.bodyH)
    }

    private func dot(_ c: Color) -> some View {
        Circle().fill(c.opacity(0.9)).frame(width: 4.5, height: 4.5)
    }
}

private struct FaceView: View {
    let pose: Pose

    var body: some View {
        ZStack {
            // Eyes
            HStack(spacing: Rig.eyeGap * 2 - Rig.eyeR * 2) {
                eye
                eye
            }
            .offset(x: pose.eyeLookX, y: Rig.eyeY)

            // Mouth
            Group {
                if pose.mouthOpen {
                    Circle()
                        .fill(pose.phosphor)
                        .frame(width: 6, height: 7)
                } else {
                    MouthShape(curve: pose.mouthCurve)
                        .stroke(pose.phosphor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: Rig.mouthW, height: 9)
                }
            }
            .offset(y: Rig.mouthY)
        }
        .shadow(color: pose.phosphor.opacity(pose.glow * 0.9), radius: 4)
    }

    @ViewBuilder private var eye: some View {
        if pose.happyEyes {
            HappyEyeShape()
                .stroke(pose.phosphor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: Rig.eyeR * 2.4, height: Rig.eyeR * 1.4)
        } else {
            Circle()
                .fill(pose.phosphor)
                .frame(width: Rig.eyeR * 2, height: Rig.eyeR * 2)
                .scaleEffect(x: pose.eyeScale, y: pose.eyeOpen * pose.eyeScale)
        }
    }
}

private struct MouthShape: Shape {
    let curve: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY
        p.move(to: CGPoint(x: r.minX, y: y))
        // +y is down in SwiftUI, so a positive control offset reads as a smile.
        p.addQuadCurve(
            to: CGPoint(x: r.maxX, y: y),
            control: CGPoint(x: r.midX, y: y + curve * 8)
        )
        return p
    }
}

private struct HappyEyeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
    }
}

/// The `> _` prompt in the corner, so it still reads as a terminal even mid-expression.
private struct PromptView: View {
    let pose: Pose
    let screenH: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            Text(">")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(pose.phosphor.opacity(0.75))
            Rectangle()
                .fill(pose.phosphor.opacity(pose.cursorOn ? 0.85 : 0))
                .frame(width: 4, height: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 6)
        .padding(.bottom, 4)
    }
}

/// Faint lines scrolling behind the face while working — "something is happening in there".
private struct ScrollLinesView: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: [22.0, 34.0, 16.0, 28.0][i], height: 2)
                        .offset(
                            x: 7,
                            y: (h + 10) - ((CGFloat(i) * 11 + phase * 11)
                                .truncatingRemainder(dividingBy: h + 10))
                        )
                }
            }
        }
    }
}

// MARK: - Limbs

private struct ArmsView: View {
    let pose: Pose

    var body: some View {
        ZStack {
            armPath(left: true, angle: pose.armAngleL)
            armPath(left: false, angle: pose.armAngleR)
        }
    }

    private func armPath(left: Bool, angle: Double) -> some View {
        let sign: CGFloat = left ? -1 : 1
        let shoulder = CGPoint(x: sign * (Rig.bodyW / 2 - 2), y: -4)
        let elbow = CGPoint(x: shoulder.x + sign * Rig.armSeg1.width,
                            y: shoulder.y + Rig.armSeg1.height)
        let hand = CGPoint(x: elbow.x + sign * Rig.armSeg2.width,
                           y: elbow.y + Rig.armSeg2.height)

        // Rotating about the shoulder; mirrored so a negative angle raises both arms.
        let deg = left ? -angle : angle
        let e = rotate(elbow, around: shoulder, degrees: deg)
        let h = rotate(hand, around: shoulder, degrees: deg)

        return LimbShape(points: [shoulder, e, h])
            .stroke(Rig.stroke, style: StrokeStyle(lineWidth: Rig.armW, lineCap: .round, lineJoin: .round))
            .frame(width: kBasePanelSize.width, height: kBasePanelSize.height)
    }
}

private struct LegsView: View {
    let pose: Pose

    var body: some View {
        // Legs tuck up a little at the top of a hop — sells the jump.
        let tuck = min(1, abs(pose.hopY) / 16) * 4
        let len = Rig.legLen - tuck

        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { sign in
                let x = CGFloat(sign) * Rig.legSpread
                let top = CGPoint(x: x, y: Rig.bodyH / 2 - 2)
                let bottom = CGPoint(x: x, y: top.y + len)

                ZStack {
                    LimbShape(points: [top, bottom])
                        .stroke(Rig.stroke, style: StrokeStyle(lineWidth: Rig.legW, lineCap: .round))
                    LimbShape(points: [
                        CGPoint(x: x - Rig.footW / 2 + 2, y: bottom.y + 1),
                        CGPoint(x: x + Rig.footW / 2, y: bottom.y + 1)
                    ])
                    .stroke(Rig.stroke, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
                .frame(width: kBasePanelSize.width, height: kBasePanelSize.height)
            }
        }
    }
}

/// Draws a polyline in centre-origin coordinates, so the rig constants above can be
/// written relative to the middle of the character rather than a corner.
private struct LimbShape: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: CGPoint(x: c.x + first.x, y: c.y + first.y))
        for pt in points.dropFirst() {
            p.addLine(to: CGPoint(x: c.x + pt.x, y: c.y + pt.y))
        }
        return p
    }
}

private func rotate(_ p: CGPoint, around o: CGPoint, degrees: Double) -> CGPoint {
    let r = degrees * .pi / 180
    let dx = p.x - o.x, dy = p.y - o.y
    return CGPoint(
        x: o.x + dx * CGFloat(cos(r)) - dy * CGFloat(sin(r)),
        y: o.y + dx * CGFloat(sin(r)) + dy * CGFloat(cos(r))
    )
}

// MARK: - Bubble & badge

private struct BubbleView: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            Capsule().fill(Rig.shell)
            Capsule().strokeBorder(Rig.stroke, lineWidth: 1.4)
            Text(symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 24)
    }
}

private struct CountBadgeView: View {
    let count: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle().strokeBorder(Rig.stroke, lineWidth: 1.2)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 17, height: 17)
    }
}
