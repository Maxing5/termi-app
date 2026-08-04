import Foundation

/// Start-at-login via a LaunchAgent.
///
/// SMAppService is the modern API but requires a properly signed bundle; with the
/// ad-hoc signing we get from Command Line Tools it's unreliable, so a plain
/// LaunchAgent plist is the primary mechanism.
///
/// `launchctl load -w` with `RunAtLoad: true` runs the job immediately, right then —
/// not just at the next real login — so enabling this while Termi is already
/// running does launch a second process for a moment. That's handled once, at the
/// root, by the single-instance guard in main.swift (the duplicate checks for an
/// existing instance and exits before creating any UI), rather than here.
enum LoginItem {

    static let label = "com.termi.app"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Path to the installed .app binary, falling back to whatever is running now.
    private static var executablePath: String {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Termi.app/Contents/MacOS/Termi").path
        if FileManager.default.fileExists(atPath: installed) { return installed }
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            ) {
                try? data.write(to: plistURL)
                run("/bin/launchctl", ["load", "-w", plistURL.path])
            }
        } else {
            run("/bin/launchctl", ["unload", "-w", plistURL.path])
            try? fm.removeItem(at: plistURL)
        }
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
