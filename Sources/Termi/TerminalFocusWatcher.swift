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

        // Never query (and never launch) Terminal unless it's already running and
        // already the frontmost app — this must be a passive observer.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return }
        guard let frontTTY = frontmostTerminalTTY() else { return }

        for session in store.pendingDoneSessions where ttyForPID(session.ppid) == frontTTY {
            store.acknowledgeDone(sessionID: session.id)
        }
    }

    /// Brings the Terminal.app window/tab that owns `session` to the front — the
    /// ⌘↩ action in the session list. Mirrors the tty matching used for dismissal,
    /// just in the other direction.
    static func focus(session: Session) {
        let helper = TerminalFocusWatcher(store: nil)
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
