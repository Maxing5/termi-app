import Foundation
import CoreGraphics

/// Ordering of rows in the session list.
enum SessionSortMode: String, CaseIterable {
    case statePriority
    case folderName
    case recentlyActive
    case longestRunning
    case custom

    var label: String {
        switch self {
        case .statePriority:  return "State priority"
        case .folderName:     return "Folder name (A–Z)"
        case .recentlyActive: return "Most recently active"
        case .longestRunning: return "Longest running"
        case .custom:         return "Custom order"
        }
    }
}

/// Persisted, user-controlled settings. Read fresh wherever needed rather than
/// plumbed through as stored properties — the views that care already re-read on
/// every animation tick or popover open.
enum MascotSettings {

    // MARK: - Size / position

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 2.5
    static let defaultScale: CGFloat = 0.8
    static let sizeStep: CGFloat = 0.10

    /// True for the whole duration of a resize gesture (slider drag or +/- press) —
    /// set by MascotPanel.beginResize/endResize, read by MascotView to hold the
    /// character's pose still while resizing rather than animating and resizing
    /// at the same time. Plain runtime state, not persisted: read fresh each
    /// animation tick, same pattern as `scale` itself.
    static var isResizingMascot = false

    private static let scaleKey = "mascotScale"
    private static let lockedKey = "mascotPositionLocked"

    static var scale: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: scaleKey) as? Double
            let value = CGFloat(stored ?? Double(defaultScale))
            return min(max(value, minScale), maxScale)
        }
        set {
            let clamped = min(max(newValue, minScale), maxScale)
            UserDefaults.standard.set(Double(clamped), forKey: scaleKey)
        }
    }

    static var positionLocked: Bool {
        get { UserDefaults.standard.bool(forKey: lockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockedKey) }
    }

    // MARK: - Popover

    /// Optional extra column. Folder name + state are always shown. Only rendered
    /// for sessions actually in `working` — see SessionListView.
    static var showElapsedTime: Bool {
        get { UserDefaults.standard.bool(forKey: "showElapsedTime") }
        set { UserDefaults.standard.set(newValue, forKey: "showElapsedTime") }
    }
    /// Account-wide, not per-session — rendered once in the popover footer rather
    /// than repeated identically on every row.
    static var showUsageLimit: Bool {
        get { UserDefaults.standard.bool(forKey: "showUsageLimit") }
        set { UserDefaults.standard.set(newValue, forKey: "showUsageLimit") }
    }

    static var sortMode: SessionSortMode {
        get { SessionSortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .statePriority }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sortMode") }
    }

    /// Custom order is keyed by working directory, not session id: session ids are
    /// regenerated every run, but the folder you work in is stable, so a hand-made
    /// order survives closing and reopening a session. Unknown folders sort last.
    static var customOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "customOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "customOrder") }
    }

    // MARK: - Alerts

    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") } // default off
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    static let minVolume: Float = 0.0
    static let maxVolume: Float = 1.0
    static let volumeStep: Float = 0.1
    static let defaultVolume: Float = 0.8

    static var volume: Float {
        get {
            guard let stored = UserDefaults.standard.object(forKey: "soundVolume") as? Double else {
                return defaultVolume
            }
            return min(max(Float(stored), minVolume), maxVolume)
        }
        set {
            let clamped = min(max(newValue, minVolume), maxVolume)
            UserDefaults.standard.set(Double(clamped), forKey: "soundVolume")
        }
    }

    static var askingSound: String {
        get { UserDefaults.standard.string(forKey: "askingSound") ?? SoundLibrary.defaultAsking }
        set { UserDefaults.standard.set(newValue, forKey: "askingSound") }
    }
    static var doneSound: String {
        get { UserDefaults.standard.string(forKey: "doneSound") ?? SoundLibrary.defaultDone }
        set { UserDefaults.standard.set(newValue, forKey: "doneSound") }
    }

    // MARK: - Updates

    /// On by default so real installs get the notice with no setup — but whoever's
    /// actively cutting releases sees a false "update available" in the gap between
    /// publishing a release and rebuilding their own local copy to match. Off is a
    /// local, one-machine choice (UserDefaults, not a build flag), so it never
    /// affects anyone else's install.
    static var updateCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "updateCheckEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateCheckEnabled") }
    }

    /// Throttles UpdateChecker to roughly once a day, regardless of how many
    /// times the app is launched or restarted in that window.
    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }
}
