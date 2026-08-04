import AppKit
import UserNotifications

/// Sound and (optional, off by default) desktop notification when a session needs
/// you or finishes. De-duplication lives in SessionStore — it only calls in on a
/// real transition — so this type just decides *how* to alert.
final class Notifier {

    static let shared = Notifier()

    private enum Keys {
        static let sound = "soundEnabled"
    }

    /// UNUserNotificationCenter throws for a process with no bundle identifier —
    /// which is how the app runs during development (`.build/debug/Termi`). Fall
    /// back to osascript there, and when an ad-hoc-signed bundle isn't registered
    /// with LaunchServices either.
    private let hasBundleIdentity = Bundle.main.bundleIdentifier != nil
    private var authorized = false

    private init() {
        UserDefaults.standard.register(defaults: [Keys.sound: true])
    }

    var soundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.sound) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sound) }
    }

    func requestAuthorizationIfPossible() {
        guard hasBundleIdentity else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async { self?.authorized = granted }
            }
    }

    func alert(_ session: Session) {
        switch session.state {
        case .asking:
            play(MascotSettings.askingSound)
            notify(title: session.folder, body: "needs you")
        case .done:
            play(MascotSettings.doneSound)
            notify(title: session.folder, body: "finished")
        case .idle, .working:
            break
        }
    }

    private func play(_ name: String) {
        guard soundEnabled else { return }
        SoundLibrary.play(name, volume: MascotSettings.volume)
    }

    // MARK: - Notification (opt-in)

    private func notify(title: String, body: String) {
        guard MascotSettings.notificationsEnabled else { return }

        if hasBundleIdentity && authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if error != nil { self?.notifyViaOsascript(title: title, body: body) }
            }
        } else {
            notifyViaOsascript(title: title, body: body)
        }
    }

    private func notifyViaOsascript(title: String, body: String) {
        // AppleScript string literals: backslash and double quote need escaping.
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"Termi\" subtitle \"\(esc(title))\""

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
