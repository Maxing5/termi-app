import SwiftUI

/// The "Mascot Size" row embedded directly in the menu bar menu (via NSMenuItem.view).
/// A slider for continuous "whatever size I want" control, plus +/- buttons that snap
/// to the nearest multiple of 10% — a reliable, predictable fallback alongside the
/// free-form slider.
struct MascotSizeControl: View {
    @State private var scale: CGFloat

    /// Bracket a resize gesture (slider drag, or a single button press) so the whole
    /// thing resizes around one fixed anchor point instead of re-centring — and
    /// re-clamping to the screen — on every intermediate step. See
    /// MascotPanel.beginResize/endResize for why that matters.
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    init(onBegin: @escaping () -> Void, onChange: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        _scale = State(initialValue: MascotSettings.scale)
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mascot Size")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button { pressStep(-1) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)

                // A plain drawn track/thumb, not SwiftUI's native Slider: AppKit
                // only renders a real NSMenuItem-embedded control in its normal
                // (blue) tint while that specific row is under the mouse —
                // otherwise it flattens to gray, which is what made this look
                // inactive. Shapes aren't NSControls, so they aren't subject to
                // that menu-tinting behavior and always show full color.
                SizeTrack(
                    value: Binding(get: { scale }, set: { set($0) }),
                    range: MascotSettings.minScale...MascotSettings.maxScale,
                    step: MascotSettings.sizeStep,
                    onEditingChanged: { editing in
                        if editing { onBegin() } else { onEnd() }
                    }
                )
                .frame(width: 130, height: 16)

                Button { pressStep(1) } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)

                Text("\(Int(scale * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 230)
    }

    /// A button press is its own self-contained gesture: bracket it in
    /// begin/end so it gets the same stable-anchor, clamp-once treatment as a
    /// slider drag, not repeated per-call re-centring.
    private func pressStep(_ direction: Int) {
        onBegin()
        step(direction)
        onEnd()
    }

    /// Steps by 10 percentage points — but if the current value isn't already a
    /// multiple of 10 (e.g. it was set by dragging the slider to 83%), the first
    /// press snaps to the nearest multiple of 10 *in the direction pressed*
    /// (83% + → 90%, 83% − → 80%) rather than overshooting to 93%/73%. Every
    /// press after that is a clean ±10 once aligned.
    private func step(_ direction: Int) {
        let current = Int((scale * 100).rounded())
        let next: Int
        if current % 10 == 0 {
            next = current + direction * 10
        } else if direction > 0 {
            next = ((current / 10) + 1) * 10
        } else {
            next = (current / 10) * 10
        }
        set(CGFloat(next) / 100)
    }

    private func set(_ value: CGFloat) {
        let clamped = min(max(value, MascotSettings.minScale), MascotSettings.maxScale)
        scale = clamped
        onChange(clamped)
    }
}

/// A minimal capsule track + thumb, drawn entirely with shapes so its fill colour
/// is never subject to AppKit's menu-item control-tinting.
private struct SizeTrack: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let onEditingChanged: (Bool) -> Void

    /// DragGesture's `onChanged` fires on every pixel of movement, not once at the
    /// start — calling `onEditingChanged(true)` from every tick re-triggers
    /// MascotPanel.beginResize() repeatedly mid-drag, which re-anchors the resize
    /// centre from whatever the frame currently is instead of holding one fixed
    /// point for the whole gesture. That reintroduced the exact drift bug the
    /// begin/end bracket was built to prevent. This flag makes the "began" edge
    /// fire exactly once per gesture, matching what SwiftUI's native Slider does.
    @State private var isDragging = false

    private var fraction: CGFloat {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = width * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, thumbX), height: 4)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: min(max(thumbX, 7), width - 7) - 7)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let raw = range.lowerBound + (g.location.x / width) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = min(max(stepped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
    }
}
