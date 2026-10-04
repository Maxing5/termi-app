import AppKit
import SwiftUI

/// Size of the panel. Deliberately larger than the character itself (~80pt) so the
/// jump animation and the `?` / `✓` bubble have room to move without being clipped.
let kBasePanelSize = CGSize(width: 160, height: 160)

private let kOriginDefaultsKey = "mascotOrigin"

/// Borderless, transparent, always-on-top panel that hosts the mascot.
final class MascotPanel: NSPanel {

    /// Called on a click that wasn't a drag.
    var onClick: (() -> Void)?

    /// When true, dragging is a no-op — set from the "Lock Position" menu item.
    var isLocked: Bool = false

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let initialSize = Self.size(forScale: MascotSettings.scale)
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        applyOverlayBehavior()

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false // we do dragging ourselves, to tell drag from click
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true       // clicking must never steal focus from your editor

        let container = MascotContainerView(frame: NSRect(origin: .zero, size: initialSize))
        container.panel = self

        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // Let the SwiftUI layer draw with a transparent backdrop.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)

        contentView = container

        restoreOrigin()
        installClickThroughMonitors()
    }

    // MARK: - Touch target (body only)

    /// The clickable area: just the terminal-window body (Rig.bodyW × Rig.bodyH),
    /// scaled with the mascot — and only while ⌘ is held. A plain click anywhere on
    /// the mascot falls through to whatever is underneath; ⌘-click on the body opens
    /// the session list, ⌘-drag moves it.
    /// The rect is the body's resting position; idle bob (±1.5pt) is ignored.
    static func bodyRect(in bounds: NSRect) -> NSRect {
        let s = bounds.width / kBasePanelSize.width
        let w = Rig.bodyW * s, h = Rig.bodyH * s
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private var bodyRectOnScreen: NSRect {
        let b = Self.bodyRect(in: NSRect(origin: .zero, size: frame.size))
        return b.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// True while the user is mid-press on the body, so a fast drag can't flip the
    /// window to click-through and drop the gesture.
    fileprivate var isPressing = false
    private var mouseMonitors: [Any] = []

    /// Polls ⌘ while the cursor is over the body. Watching modifier keys of other
    /// apps with a global flagsChanged monitor would need Accessibility permission;
    /// `NSEvent.modifierFlags` doesn't, and this only runs while hovering the body.
    private var modifierPoll: Timer?

    /// A transparent window only lets clicks fall through where its pixels are fully
    /// clear; the arms/legs are opaque. So we toggle `ignoresMouseEvents` from the
    /// cursor position: the window only takes the mouse while it's over the body.
    private func installClickThroughMonitors() {
        acceptsMouseMovedEvents = true
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.updateClickThrough()
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
            self?.updateClickThrough(); return e
        }) { mouseMonitors.append(l) }
    }

    func updateClickThrough() {
        guard isShown, !isPressing else { return }
        let overBody = bodyRectOnScreen.contains(NSEvent.mouseLocation)
        if overBody, modifierPoll == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateClickThrough()
            }
            RunLoop.main.add(t, forMode: .common)
            modifierPoll = t
        } else if !overBody {
            modifierPoll?.invalidate()
            modifierPoll = nil
        }
        let interactive = overBody && NSEvent.modifierFlags.contains(.command)
        if ignoresMouseEvents == interactive { ignoresMouseEvents = !interactive }
    }

    // MARK: - Every Space, every screen

    /// Space membership the panel needs to behave as an overlay on every desktop and
    /// every full-screen app.
    private static let overlayBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    private func applyOverlayBehavior() {
        level = .statusBar                 // above normal windows *and* full-screen apps
        collectionBehavior = Self.overlayBehavior
    }

    /// Whether the mascot is meant to be seen. Distinct from `isVisible`: the panel
    /// is never ordered out, because a `.canJoinAllSpaces` window that is ordered out
    /// and back in comes back pinned to the current Space only (measured on macOS 26
    /// with CGSCopySpacesForWindows: membership collapsed to the single active Space).
    /// Hiding is therefore alpha 0 + click-through, which keeps the window a member
    /// of every Space.
    private(set) var isShown = false

    func show() {
        isShown = true
        alphaValue = 1
        ignoresMouseEvents = false
        updateClickThrough()
        reassertOnActiveSpace()
    }

    func hide() {
        isShown = false
        alphaValue = 0
        ignoresMouseEvents = true
    }

    /// Re-applies the all-Spaces behavior and orders the panel in on whatever Space
    /// is active. Called on show and on every Space switch, so a full-screen app's
    /// Space (created after the panel was) still gets the mascot.
    func reassertOnActiveSpace() {
        applyOverlayBehavior()
        orderFrontRegardless()
    }

    // A .nonactivatingPanel may become key without activating the app, which the
    // session-list popover needs in order to receive clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Size

    private static func size(forScale scale: CGFloat) -> CGSize {
        CGSize(width: kBasePanelSize.width * scale, height: kBasePanelSize.height * scale)
    }

    /// Fixed centre point for the resize gesture currently in progress. Re-deriving
    /// the centre from `frame` on every intermediate `setScale` call (as a fast
    /// slider drag does, many times a second) let tiny rounding compound across
    /// calls, and running `clampToVisibleScreen` on every tick could snap to a
    /// corner mid-drag if an edge briefly brushed the screen's intersection
    /// tolerance. Anchoring once for the whole gesture fixes both: every
    /// intermediate size is centred on the exact same point, so the mascot cannot
    /// drift, and screen-clamping only happens once the gesture actually ends.
    private var resizeAnchor: NSPoint?

    /// Call once when a resize interaction begins (slider drag start, or a single
    /// +/- button press treated as a one-tick gesture).
    func beginResize() {
        resizeAnchor = NSPoint(x: frame.midX, y: frame.midY)
        MascotSettings.isResizingMascot = true
    }

    /// Resizes around `resizeAnchor` if a gesture is in progress, else around the
    /// panel's current centre (a safe fallback for any one-off caller).
    func setScale(_ scale: CGFloat) {
        let newSize = Self.size(forScale: scale)
        let center = resizeAnchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let newOrigin = NSPoint(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2)
        setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        updateClickThrough()
    }

    /// Call once when the resize interaction ends: clamps back on screen if the
    /// final size pushed it off, and persists the resulting origin.
    func endResize() {
        resizeAnchor = nil
        MascotSettings.isResizingMascot = false
        clampToVisibleScreen()
        saveOrigin()
    }

    // MARK: - Position persistence

    func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: kOriginDefaultsKey)
    }

    private func restoreOrigin() {
        if let s = UserDefaults.standard.string(forKey: kOriginDefaultsKey) {
            let p = NSPointFromString(s)
            setFrameOrigin(p)
            clampToVisibleScreen()
        } else {
            moveToDefaultCorner()
        }
    }

    func moveToDefaultCorner() {
        guard let vis = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24
        setFrameOrigin(NSPoint(x: vis.maxX - frame.width - margin,
                               y: vis.minY + margin))
    }

    /// If a monitor was unplugged, an old saved origin can put the panel off-screen.
    func clampToVisibleScreen() {
        let f = frame
        // Fine if it meaningfully overlaps any current screen.
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(f.insetBy(dx: 20, dy: 20)) }
        if !visible { moveToDefaultCorner() }
    }
}

/// Takes every mouse event for the panel (SwiftUI content is purely visual) so we can
/// cleanly distinguish a drag from a click.
private final class MascotContainerView: NSView {

    weak var panel: MascotPanel?

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var travelled: CGFloat = 0

    /// Only the body is a touch target. Hits there are swallowed (never reach the
    /// hosting view); hits anywhere else return nil.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return MascotPanel.bodyRect(in: bounds).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel, event.modifierFlags.contains(.command) else { return }
        panel.isPressing = true
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        travelled = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel, panel.isPressing, !panel.isLocked else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        travelled = max(travelled, hypot(dx, dy))
        panel.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel, panel.isPressing else { return }
        panel.isPressing = false
        defer { panel.updateClickThrough() }
        if travelled < 3 {
            panel.onClick?()
        } else {
            panel.saveOrigin()
        }
    }
}
