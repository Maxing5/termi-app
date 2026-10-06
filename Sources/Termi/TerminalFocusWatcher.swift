import AppKit
import Foundation

/// Dismisses a pending `done` badge the moment you switch to the specific Terminal.app
/// window/tab that owns it — not when you type something there. That's the
/// distinction that matters: opening the terminal is enough, no action required.
///
/// `asking` is deliberately NOT handled here: its badge only clears when the question
/// is actually answered (a real hook fires, moving that session to `working`) —
/// opening the terminal isn't enough on its own for that one.
///
/// Only Terminal.app (the built-in terminal) is supported, since that's what every
/// session on this machine runs under (confirmed via process ancestry — each `claude`
/// process's parent shell traces back to /System/Applications/Utilities/Terminal.app).
/// Polling only ever talks to Terminal when it's already running and already
/// frontmost, so this can never launch it or steal focus.
final class TerminalFocusWatcher {

    private weak var store: SessionStore?
    private var timer: Timer?

    init(store: SessionStore?) {
        self.store = store
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Tuning.focusPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let store, !store.pendingDoneSessions.isEmpty else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }

        if Self.editorBundleIDs.contains(front.bundleIdentifier ?? "") {
            pollEditor(front, store: store)
            return
        }

        // Never query (and never launch) Terminal unless it's already running and
        // already the frontmost app — this must be a passive observer.
        guard front.bundleIdentifier == "com.apple.Terminal" else { return }
        guard let frontTTY = frontmostTerminalTTY() else { return }

        for session in store.pendingDoneSessions where ttyForPID(session.ppid) == frontTTY {
            store.acknowledgeDone(sessionID: session.id)
        }
    }

    // MARK: - VS Code-family editors (integrated terminal)

    /// Editors whose integrated terminal hosts sessions. None of them expose the
    /// active terminal's tty to AppleScript, so matching is by process ancestry
    /// (the session's `claude` process descends from the frontmost editor), narrowed
    /// to the focused window by its title when Accessibility access is available.
    static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
        "com.vscodium",
    ]

    private func pollEditor(_ app: NSRunningApplication, store: SessionStore) {
        let editorPID = app.processIdentifier
        let candidates = store.pendingDoneSessions.filter { isDescendant($0.ppid, of: editorPID) }
        guard !candidates.isEmpty else { return }

        // With a window title, only clear sessions whose folder that window shows
        // (VS Code titles read "file — folder — …"). Without one (no Accessibility
        // permission), clear every session in this editor rather than never clearing.
        if let title = focusedWindowTitle(pid: editorPID) {
            let parts = Set(title.components(separatedBy: " — ").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            for s in candidates where Self.pathComponents(s.cwd).contains(where: parts.contains) {
                store.acknowledgeDone(sessionID: s.id)
            }
        } else {
            for s in candidates { store.acknowledgeDone(sessionID: s.id) }
        }
    }

    /// The session's cwd may be a subfolder of the window's workspace root, so any
    /// path component may be the one shown in the title.
    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    /// Walks parent pids via sysctl (no subprocess spawns) up to launchd.
    private func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<32 {
            if current == ancestor { return true }
            guard current > 1, let parent = parentPID(of: current) else { return false }
            current = parent
        }
        return false
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Focused window title via Accessibility. Never prompts — returns nil if Termi
    /// isn't trusted, which makes the caller fall back to ancestry-only matching.
    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let str = title as? String, !str.isEmpty else { return nil }
        return str
    }

    /// Brings the Terminal.app window/tab that owns `session` to the front — the
    /// ⌘↩ action in the session list. Mirrors the tty matching used for dismissal,
    /// just in the other direction.
    static func focus(session: Session) {
        let helper = TerminalFocusWatcher(store: nil)
        // Integrated-terminal sessions: bring the owning editor forward (it can't be
        // told which terminal tab to select, so the app is as precise as it gets).
        if let editor = NSWorkspace.shared.runningApplications.first(where: {
            editorBundleIDs.contains($0.bundleIdentifier ?? "")
                && helper.isDescendant(session.ppid, of: $0.processIdentifier)
        }) {
            editor.activate()
            return
        }
        guard let tty = helper.ttyForPID(session.ppid) else { return }
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set frontmost of w to true
                        set selected tab of w to t
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = helper.run("/usr/bin/osascript", ["-e", script])
    }

    private func frontmostTerminalTTY() -> String? {
        let script = "tell application \"Terminal\" to get tty of selected tab of front window"
        guard let out = run("/usr/bin/osascript", ["-e", script]) else { return nil }
        return normalizeTTY(out)
    }

    fileprivate func ttyForPID(_ pid: pid_t) -> String? {
        guard let out = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "??") ? nil : trimmed
    }

    /// AppleScript reports "/dev/ttys002"; `ps` reports "ttys002" — normalize both to
    /// the bare form before comparing.
    private func normalizeTTY(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/dev/") { t.removeFirst(5) }
        return t
    }

    fileprivate func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
