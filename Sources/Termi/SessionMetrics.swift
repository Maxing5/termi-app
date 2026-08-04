import Foundation

/// Account-wide rate-limit percentages, cached by the statusline script (see
/// `install-statusline.sh`) — Claude Code only pipes rate limits to statusline
/// commands, so there's no other source for this on disk. Also formats the
/// popover's elapsed-time column.
final class SessionMetrics {

    static let shared = SessionMetrics()

    // MARK: - Rate limits

    struct Limits {
        let fiveHourPercent: Double?
        let sevenDayPercent: Double?
    }

    /// Absent or stale simply means the footer isn't shown.
    static var limitsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/termi/limits.json")
    }

    func limits() -> Limits? {
        guard let data = try? Data(contentsOf: Self.limitsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Limits(
            fiveHourPercent: obj["five_hour"] as? Double,
            sevenDayPercent: obj["seven_day"] as? Double
        )
    }

    // MARK: - Formatting

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let secs = Int(interval)
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }
}
