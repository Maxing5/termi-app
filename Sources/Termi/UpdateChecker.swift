import Foundation

/// One-shot "is there a newer release" check against GitHub — no auto-install,
/// just a passive notice. Termi is ad-hoc signed rather than Developer-ID
/// signed + notarized, so a real Sparkle-style silent install would still hit
/// Gatekeeper the same way a fresh download does; this just tells you a fix
/// exists so you know to `git pull && ./install.sh`.
enum UpdateChecker {

    private static let releasesURL =
        URL(string: "https://api.github.com/repos/Maxing5/termi-app/releases/latest")!

    /// Throttled to ~once/day via MascotSettings.lastUpdateCheck, well under
    /// GitHub's 60 req/hr unauthenticated rate limit. Any failure — offline,
    /// malformed JSON, no releases yet — simply means no menu item shows up;
    /// there's no error case the caller needs to handle.
    static func checkForUpdate(completion: @escaping (String, URL) -> Void) {
        if let last = MascotSettings.lastUpdateCheck, Date().timeIntervalSince(last) < 20 * 3600 {
            return
        }
        // Run unbundled (`swift build && .build/debug/Termi`, per the README's
        // dev workflow) means no Info.plist, so there's nothing to compare
        // against — skip rather than risk a false positive.
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return }

        URLSession.shared.dataTask(with: releasesURL) { data, _, _ in
            MascotSettings.lastUpdateCheck = Date()

            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let htmlURLString = obj["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString)
            else { return }

            let latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(latestVersion, than: currentVersion) else { return }

            DispatchQueue.main.async {
                completion(latestVersion, htmlURL)
            }
        }.resume()
    }

    /// Plain string comparison would rank "1.9" above "1.10" — compare
    /// numerically component by component instead. Missing/non-numeric
    /// components count as 0, so "1.2" and "1.2.0" are treated as equal.
    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
