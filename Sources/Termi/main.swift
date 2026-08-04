import AppKit
import Foundation

/// Enforce a single running instance. Without this, launching a second copy —
/// double-clicking the app while it's already open, `open -a` from the shell, or
/// `launchctl load -w`'s `RunAtLoad` firing immediately when "Start at Login" is
/// toggled on while Termi is already running (see LoginItem.setEnabled) — would show
/// two independent mascots. Checked and exited *before* NSApplication or any UI is
/// touched, so a duplicate launch never visibly flashes on screen at all.
func anotherInstanceIsRunning() -> Bool {
    let myPID = ProcessInfo.processInfo.processIdentifier

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-ax", "-o", "pid=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return false }

    return output.split(separator: "\n").contains { line in
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        // `ps -o comm=` reports a bare name when the process was resolved off PATH,
        // but the full executable path when launched via an absolute path (as
        // `open -a`, launchd, and Finder all do for this app) — compare on the
        // last path component so both forms match.
        guard parts.count == 2,
              (parts[1] as NSString).lastPathComponent == "Termi",
              let pid = Int32(parts[0])
        else { return false }
        return pid != myPID
    }
}

if anotherInstanceIsRunning() {
    exit(0)
}

// No Dock icon, no menu bar of its own — Termi lives as an accessory app whose
// only surfaces are the floating mascot panel and an NSStatusItem.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
