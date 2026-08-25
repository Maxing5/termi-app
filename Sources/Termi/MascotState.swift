import Foundation

/// The state of a single Claude Code session, as written by termi-state.sh.
enum SessionState: String, Codable {
    case idle
    case working
    case asking
    case done

    /// Higher wins when several sessions disagree. A session that needs you
    /// outranks everything; a finished one outranks one still grinding away.
    var priority: Int {
        switch self {
        case .asking:  return 3
        case .done:    return 2
        case .working: return 1
        case .idle:    return 0
        }
    }

    var label: String {
        switch self {
        case .idle:    return "idle"
        case .working: return "working"
        case .asking:  return "needs you"
        case .done:    return "finished"
        }
    }
}

/// What the mascot is rendering. Distinct from SessionState because "no sessions at
/// all" is a real display state.
enum MascotDisplayState: Equatable {
    case none
    case idle
    case working
    case asking
    case done
}

struct Session: Identifiable, Equatable {
    let id: String
    let cwd: String
    let state: SessionState
    let ppid: pid_t
    let ts: TimeInterval
    /// Set by termi-state.sh when `working` reflects a known-pending backgrounded
    /// shell rather than an actual in-progress turn — see its own comment for why.
    /// Exempts the session from the app-side stale-working-means-interrupted timeout.
    let pendingBackground: Bool

    /// Last path component, for the session list — "portfolio" reads better than a full path.
    var folder: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Raw on-disk shape. Kept separate from `Session` so a malformed or future field
/// can't break decoding of the rest.
struct SessionFile: Decodable {
    let session_id: String
    let cwd: String?
    let state: String?
    let ppid: Int?
    let ts: Double?
    let pendingBackground: Bool?
}

enum Tuning {
    /// How long the mascot's own "finished!"/"?" pose plays before settling back to
    /// idle on its own. Deliberately temporary/ambient for both — the persistent
    /// "this needs you" signal is the done/asking badges, not the big pose, which is
    /// tracked separately and dismissed only via the terminal itself.
    static let poseCelebrationDuration: TimeInterval = 4.0
    /// Sessions older than this are presumed dead even if their pid was recycled.
    static let staleAfter: TimeInterval = 12 * 60 * 60
    /// Claude Code fires no hook at all when a turn is manually interrupted (verified
    /// against the official hooks docs: "Stop hooks... don't fire on user interrupts") —
    /// so a session frozen in `working` with no PostToolUse heartbeat this long is
    /// presumed interrupted rather than genuinely still going, and displays as idle.
    static let staleWorkingTimeout: TimeInterval = 5 * 60
    /// Coalesce bursts of file writes (a turn can fire several hooks in a few ms).
    static let watchDebounce: TimeInterval = 0.08
    /// Cadence of the liveness/staleness sweep.
    static let pruneInterval: TimeInterval = 60
    /// Cadence of the "did you switch to the terminal that's asking/done" check.
    /// Only runs at all while something is actually pending, so a 1s poll is cheap.
    static let focusPollInterval: TimeInterval = 1.0
}
