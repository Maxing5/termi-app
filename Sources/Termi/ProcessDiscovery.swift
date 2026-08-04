import Foundation

/// Finds Claude Code CLI processes that have no session file yet.
///
/// Hooks only fire for sessions that start (or take a turn) after they're registered,
/// so a `claude` process already running when Termi's hooks were installed — or one
/// that's been silently idle since — is invisible to the file-based state layer.
/// This closes that gap by cross-checking the process list against tracked ppids.
enum ProcessDiscovery {

    /// Synthetic sessions for every running `claude` CLI process not already covered
    /// by `excludingPPIDs`. State is always `idle` since no hook has told us
    /// otherwise — better an undercolored dot than a wrong color.
    ///
    /// The folder name is resolved two ways, in order of trust:
    ///  1. Match against an orphaned transcript (see `orphanedTranscriptCwd`) — its
    ///     `cwd` field is Claude Code's own authoritative value.
    ///  2. Fall back to `lsof`'s raw OS-level process cwd, which is frequently just
    ///     wrong: Claude Code doesn't `chdir()` into the project it's working in,
    ///     so this is often just the shell's launch directory (commonly home).
    static func discoverUntracked(excludingPPIDs: Set<pid_t>, trackedSessionIDs: Set<String>) -> [Session] {
        let pids = pidsRunningClaude()
        let candidates = pids.filter { !excludingPPIDs.contains($0) }
        guard !candidates.isEmpty else { return [] }

        // Only bother resolving orphaned transcripts if there's actually a gap to
        // fill — this list can be empty most of the time (every session correctly
        // tracked), so skip the extra directory scan then.
        let orphanCwds = orphanedTranscriptCwds(excluding: trackedSessionIDs)

        // Trust the transcript match only when it's completely unambiguous: one
        // untracked process, one orphaned transcript. With more of either there's
        // no reliable way to know which process owns which transcript (Claude
        // Code records a pid in neither), and a wrong-but-plausible-looking pairing
        // would be worse than the honest (if blunter) lsof fallback.
        let unambiguousMatch = (candidates.count == 1 && orphanCwds.count == 1) ? orphanCwds[0] : nil

        return candidates.compactMap { pid -> Session? in
            guard let cwd = unambiguousMatch ?? currentDirectory(ofPID: pid) else { return nil }
            return Session(
                id: "discovered-\(pid)",
                cwd: cwd,
                state: .idle,
                ppid: pid,
                ts: Date().timeIntervalSince1970
            )
        }
    }

    /// `pgrep -x claude` is unreliable here (observed missing a live pid in testing);
    /// a plain `ps` listing filtered by exact command name is what actually catches
    /// every one.
    private static func pidsRunningClaude() -> [pid_t] {
        guard let output = run("/bin/ps", ["-ax", "-o", "pid=,comm="]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, parts[1] == "claude", let pid = pid_t(parts[0]) else { return nil }
            return pid
        }
    }

    /// `cwd` values of recently-active transcripts whose session isn't currently
    /// tracked by a real file — i.e. sessions Termi lost track of (see the 12-hour
    /// staleness bug this was built to compensate for) while their `claude`
    /// process kept running. Only transcripts modified in the last 24h count as
    /// "recently active"; a transcript from days ago almost certainly belongs to a
    /// session that's genuinely long gone, not a currently-live orphan.
    ///
    /// This is a best-effort match, not a guaranteed one: when there's exactly one
    /// untracked process and one orphaned transcript, pairing them is very likely
    /// correct. With several of each there's no reliable way to tell *which*
    /// process owns *which* transcript (Claude Code doesn't record a pid in
    /// either), so the caller only uses this list when the counts line up exactly
    /// and otherwise falls back to the older, less accurate `lsof` guess.
    private static func orphanedTranscriptCwds(excluding trackedSessionIDs: Set<String>) -> [String] {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return [] }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var results: [(modified: Date, cwd: String)] = []

        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard !trackedSessionIDs.contains(sessionID) else { continue }
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = attrs.contentModificationDate, modified > cutoff
                else { continue }
                guard let cwd = lastCwd(inTranscript: file) else { continue }
                results.append((modified, cwd))
            }
        }

        return results.sorted { $0.modified > $1.modified }.map(\.cwd)
    }

    /// Reads the `cwd` field off the last line of a transcript that has one —
    /// every hook payload Claude Code writes includes it.
    private static func lastCwd(inTranscript url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    private static func currentDirectory(ofPID pid: pid_t) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
