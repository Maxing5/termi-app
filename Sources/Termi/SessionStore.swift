import Foundation
import Combine

/// Watches ~/.claude/termi/sessions and turns the files there into live mascot state.
///
/// The store is deliberately the only thing that knows about the filesystem: the views
/// see `sessions` and `displayState`, nothing else.
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var displayState: MascotDisplayState = .none

    /// Fires on a transition *into* asking/done, once per session per occurrence.
    /// Used for sound + notification; never fires on a plain reload or app restart.
    var onAlert: ((Session) -> Void)?

    /// Overridable via TERMI_DIR so the app can be driven against a scratch directory
    /// for testing without interfering with real sessions.
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["TERMI_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/termi/sessions")
    }()

    private var dirFD: CInt = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var pruneTimer: Timer?
    private var doneDecayTimer: Timer?

    /// When each session was first observed in `done`/`asking`, so the mascot's own
    /// *pose* can settle back to idle on its own after a few seconds — same temporary
    /// treatment for both. This is entirely separate from the badges (done-count via
    /// `doneAcknowledged`, asking-count via raw state): the pose is a brief animation,
    /// the badges are the persistent "this needs your attention" signal.
    private var doneFirstSeen: [String: Date] = [:]
    private var askingFirstSeen: [String: Date] = [:]

    /// When each session most recently entered `working`, for the popover's optional
    /// "elapsed time on current turn" column. Cleared as soon as it leaves working.
    private var workingSince: [String: Date] = [:]

    /// When each session was last seen in any non-idle state — used by the
    /// "most recently active" sort.
    private var lastActive: [String: Date] = [:]

    /// Done sessions dismissed by reopening their terminal (TerminalFocusWatcher).
    /// Only `done` uses this — `asking` has no acknowledgment concept at all; its
    /// badge just reflects raw state and clears the moment that session is actually
    /// answered (a real hook fires, moving it to `working`).
    private var doneAcknowledged: Set<String> = []

    /// Last state we alerted on, per session — also how we detect "the underlying
    /// state changed", which re-arms `doneAcknowledged` for whatever comes next.
    private var lastAlerted: [String: SessionState] = [:]
    /// True until the first load completes, so launching with sessions already in
    /// `done` doesn't fire a burst of stale notifications.
    private var isFirstLoad = true

    // MARK: - Lifecycle

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        refreshDiscoveredCache {
            self.reload()
            self.isFirstLoad = false
            self.startWatching()
        }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: Tuning.pruneInterval, repeats: true) { [weak self] _ in
            self?.refreshDiscoveredCache { self?.reload() }
        }
    }

    /// Cached result of the last process scan. `ps`/`lsof` are real subprocess spawns,
    /// so they run only here — on the 60s sweep and at launch — never from the
    /// file-watch path, which can fire on every tool call while a session works.
    private var discoveredCache: [Session] = []

    /// ppids backed by a real hook-written file, as of the last `reload()`. Deliberately
    /// separate from `sessions` (which also contains our own synthetic "discovered-*"
    /// entries): excluding based on `sessions` caused each scan's own discoveries to
    /// count as "already tracked" on the *next* scan, so they'd be dropped from
    /// `discoveredCache` one cycle after being added, then rediscovered the cycle after
    /// that — an every-60s flicker between the full count and just the real sessions.
    private var realPPIDs: Set<pid_t> = []
    /// Session ids backed by a real hook-written file, as of the last `reload()`.
    /// Passed to ProcessDiscovery so it can exclude these transcripts when looking
    /// for an orphaned one to recover a lost session's true cwd from — see
    /// ProcessDiscovery.discoverUntracked.
    private var realSessionIDs: Set<String> = []

    private func refreshDiscoveredCache(then completion: @escaping () -> Void) {
        guard Self.discoveryEnabled else { completion(); return }
        let trackedPPIDs = realPPIDs
        let trackedIDs = realSessionIDs
        DispatchQueue.global(qos: .utility).async {
            let found = ProcessDiscovery.discoverUntracked(excludingPPIDs: trackedPPIDs, trackedSessionIDs: trackedIDs)
            DispatchQueue.main.async {
                self.discoveredCache = found
                completion()
            }
        }
    }

    private func startWatching() {
        dirFD = open(Self.directory.path, O_EVTONLY)
        guard dirFD >= 0 else {
            NSLog("Termi: cannot watch \(Self.directory.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main
        )
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        src.resume()
        watchSource = src
    }

    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.watchDebounce, execute: work)
    }

    // MARK: - Loading

    /// True for the app's normal, real-directory mode. Process discovery is skipped
    /// under TERMI_DIR so demo.sh's synthetic sessions aren't mixed with whatever
    /// `claude` processes happen to be running on the machine at the time.
    private static let discoveryEnabled = ProcessInfo.processInfo.environment["TERMI_DIR"] == nil

    private func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory,
                                                includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970
        var loaded: [Session] = []

        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode(SessionFile.self, from: data)
            else { continue }

            let ppid = pid_t(raw.ppid ?? 0)
            let ts = raw.ts ?? now

            // A kill -9'd terminal never fires SessionEnd, so prune by liveness.
            // kill(pid, 0) succeeds for a live process; EPERM also means alive.
            //
            // For a real, verifiable pid, liveness is the *only* thing that
            // matters — Tuning.staleAfter must never additionally condemn a
            // session just for being old. A laptop closed overnight (or longer)
            // leaves every idle-but-still-running session well past 12 hours
            // since its last hook write; deleting those files anyway (as this
            // used to) forces Termi to fall back to process discovery for them,
            // whose cwd comes from `lsof`'s raw OS-level working directory —
            // often just the shell's home directory, not the real project
            // folder. staleAfter still applies to ppid<=0 fake/demo entries,
            // which have no real pid to verify liveness against at all.
            let alive: Bool
            if ppid > 0 {
                alive = kill(ppid, 0) == 0 || errno == EPERM
            } else {
                alive = (now - ts) <= Tuning.staleAfter
            }

            if !alive {
                try? fm.removeItem(at: url)
                continue
            }

            loaded.append(Session(
                id: raw.session_id,
                cwd: raw.cwd ?? "",
                state: SessionState(rawValue: raw.state ?? "") ?? .idle,
                ppid: ppid,
                ts: ts
            ))
        }

        realPPIDs = Set(loaded.map(\.ppid))
        realSessionIDs = Set(loaded.map(\.id))

        if Self.discoveryEnabled {
            loaded.append(contentsOf: discoveredCache.filter { !realPPIDs.contains($0.ppid) })
        }

        loaded.sort { $0.id < $1.id }
        let live = Set(loaded.map(\.id))
        doneFirstSeen = doneFirstSeen.filter { live.contains($0.key) }
        askingFirstSeen = askingFirstSeen.filter { live.contains($0.key) }
        doneAcknowledged = doneAcknowledged.intersection(live)

        reArmDoneAcknowledgment(loaded)
        sessions = loaded
        trackCelebrationTimestamps(loaded)
        emitAlerts(loaded)
        recomputeDisplayState()
    }

    // MARK: - Mascot pose decay (temporary — both the "done!" and "?" poses)

    private func trackCelebrationTimestamps(_ loaded: [Session]) {
        for s in loaded {
            doneFirstSeen[s.id] = s.state == .done ? (doneFirstSeen[s.id] ?? Date()) : nil
            askingFirstSeen[s.id] = s.state == .asking ? (askingFirstSeen[s.id] ?? Date()) : nil
            workingSince[s.id] = s.state == .working ? (workingSince[s.id] ?? Date()) : nil
            if s.state != .idle { lastActive[s.id] = Date() }
        }
    }

    /// How long the current turn has been running, for sessions that are working.
    func elapsedWorking(for session: Session) -> TimeInterval? {
        guard session.state == .working, let since = workingSince[session.id] else { return nil }
        return Date().timeIntervalSince(since)
    }

    /// Rows in the order the user asked for. `listState` is used for the state-priority
    /// sort so an acknowledged `done` sinks with the idle rows rather than staying on top.
    func sortedSessions() -> [Session] {
        let mode = MascotSettings.sortMode
        switch mode {
        case .statePriority:
            return sessions.sorted {
                let (a, b) = (listState(for: $0).priority, listState(for: $1).priority)
                return a == b ? $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending : a > b
            }
        case .folderName:
            return sessions.sorted { $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending }
        case .recentlyActive:
            return sessions.sorted {
                (lastActive[$0.id] ?? .distantPast) > (lastActive[$1.id] ?? .distantPast)
            }
        case .longestRunning:
            return sessions.sorted { $0.ts < $1.ts }
        case .custom:
            // Keyed by cwd so a hand-made order survives a session restarting in the
            // same folder. Anything not in the list sorts after, alphabetically.
            let order = MascotSettings.customOrder
            return sessions.sorted { a, b in
                let ia = order.firstIndex(of: a.cwd) ?? Int.max
                let ib = order.firstIndex(of: b.cwd) ?? Int.max
                if ia != ib { return ia < ib }
                return a.folder.localizedCaseInsensitiveCompare(b.folder) == .orderedAscending
            }
        }
    }

    /// What the mascot's *big pose* should treat a session as. Both `done` and
    /// `asking` decay to `idle` after Tuning.poseCelebrationDuration regardless of
    /// whether the underlying question/finish is still unresolved — the pose is just
    /// a brief animation; the badges (done-count, asking-count) are what actually
    /// persists until you deal with it.
    private func poseState(_ s: Session) -> SessionState {
        switch s.state {
        case .done:
            guard let seen = doneFirstSeen[s.id] else { return .done }
            return Date().timeIntervalSince(seen) > Tuning.poseCelebrationDuration ? .idle : .done
        case .asking:
            guard let seen = askingFirstSeen[s.id] else { return .asking }
            return Date().timeIntervalSince(seen) > Tuning.poseCelebrationDuration ? .idle : .asking
        default:
            return s.state
        }
    }

    // MARK: - Done badge acknowledgment (persistent — dismissed only by reopening
    // the terminal; see TerminalFocusWatcher)

    /// If a session's real state changed since the last reload, any earlier
    /// acknowledgment was about a `done` that no longer exists — clear it so the
    /// *next* time it finishes, the badge shows fresh.
    private func reArmDoneAcknowledgment(_ loaded: [Session]) {
        for s in loaded where lastAlerted[s.id] != nil && lastAlerted[s.id] != s.state {
            doneAcknowledged.remove(s.id)
        }
    }

    /// Dismisses one done session's badge — called by TerminalFocusWatcher when you
    /// switch back to the terminal that finished. Asking has no equivalent: its badge
    /// clears only when the session is actually answered (a real hook fires).
    ///
    /// `doneAcknowledged` isn't @Published (it's not something MascotView needs a
    /// publish for — it already re-reads the badge counts on every 30fps animation
    /// tick regardless), but the session-list popover only redraws on an actual
    /// Combine publish. Without this, dismissing a session's badge by reopening its
    /// terminal wouldn't be reflected in the popover until the next unrelated hook
    /// write happened to trigger a reload — a visible, unpredictable lag.
    func acknowledgeDone(sessionID: String) {
        guard doneAcknowledged.insert(sessionID).inserted else { return }
        objectWillChange.send()
    }

    /// Done sessions still counting toward the badge — what TerminalFocusWatcher
    /// polls for and matches by tty.
    var pendingDoneSessions: [Session] {
        sessions.filter { $0.state == .done && !doneAcknowledged.contains($0.id) }
    }

    /// Badge counts. Plain computed properties, not @Published: MascotView reads
    /// these fresh on every animation tick already, so no separate publish is needed.
    var doneBadgeCount: Int {
        sessions.filter { $0.state == .done && !doneAcknowledged.contains($0.id) }.count
    }
    var askingBadgeCount: Int {
        sessions.filter { $0.state == .asking }.count
    }

    // MARK: - Alerts

    private func emitAlerts(_ loaded: [Session]) {
        guard !isFirstLoad else {
            for s in loaded { lastAlerted[s.id] = s.state }
            return
        }
        for s in loaded {
            let previous = lastAlerted[s.id]
            if previous != s.state, s.state == .asking || s.state == .done {
                onAlert?(s)
            }
            lastAlerted[s.id] = s.state
        }
    }

    // MARK: - Aggregate (the mascot's big pose)

    private func recomputeDisplayState() {
        doneDecayTimer?.invalidate()

        guard !sessions.isEmpty else {
            displayState = .none
            return
        }

        let top = sessions.map(poseState).max(by: { $0.priority < $1.priority }) ?? .idle
        displayState = {
            switch top {
            case .idle:    return .idle
            case .working: return .working
            case .asking:  return .asking
            case .done:    return .done
            }
        }()

        // Nothing writes a file when the celebration expires, so schedule the re-check.
        if top == .done || top == .asking {
            let firstSeen = top == .done ? doneFirstSeen : askingFirstSeen
            let soonest = firstSeen.values.map {
                Tuning.poseCelebrationDuration - Date().timeIntervalSince($0)
            }.filter { $0 > 0 }.min() ?? Tuning.poseCelebrationDuration

            doneDecayTimer = Timer.scheduledTimer(withTimeInterval: soonest + 0.05, repeats: false) { [weak self] _ in
                self?.recomputeDisplayState()
            }
        }
    }

    /// Per-session state for the popover list. Not decayed by the pose timer (a
    /// `done` still shows as finished well past the mascot's brief celebration), but
    /// it does reflect the done badge's own acknowledgment: once you've reopened that
    /// terminal and the green badge cleared, the list should agree and show idle
    /// rather than a "finished" that nothing else on screen still claims.
    func listState(for session: Session) -> SessionState {
        if session.state == .done, doneAcknowledged.contains(session.id) { return .idle }
        return session.state
    }
}
