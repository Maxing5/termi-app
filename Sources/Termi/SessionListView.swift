import SwiftUI

/// Contents of the popover: every open session, its folder, state, and whichever
/// optional columns are enabled in Preferences.
struct SessionListView: View {
    @ObservedObject var store: SessionStore

    /// Index of the keyboard-highlighted row, driven by ⌘↑/⌘↓ (see KeyboardNavState).
    @ObservedObject var nav: KeyboardNavState

    /// Ticks so the elapsed-time column stays live while the popover is open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let sessions = store.sortedSessions()
        let showElapsed = MascotSettings.showElapsedTime

        VStack(alignment: .leading, spacing: 0) {
            header

            if sessions.isEmpty {
                Text("No sessions open")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                ForEach(sessions, id: \.id) { session in
                    row(session, showElapsed: showElapsed)
                }
            }

            if MascotSettings.showUsageLimit { usageFooter }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .onReceive(tick) { now = $0 }
        .onAppear { nav.orderedIDs = sessions.map(\.id) }
        .onChange(of: sessions.map(\.id)) { nav.orderedIDs = sessions.map(\.id) }
    }

    /// Grows when the elapsed-time column is enabled so nothing truncates awkwardly.
    private var width: CGFloat {
        MascotSettings.showElapsedTime ? 322 : 260
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Code sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            // Compact reminder that the list is keyboard-navigable.
            HStack(spacing: 2) {
                keyCap("command")
                keyCap("arrow.up")
                keyCap("arrow.down")
            }
        }
        .padding(.bottom, 8)
    }

    private func keyCap(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.14))
            )
    }

    // MARK: - Rows

    private func row(_ session: Session, showElapsed: Bool) -> some View {
        let state = store.listState(for: session)
        let isHighlighted = nav.highlightedID == session.id

        return HStack(spacing: 8) {
            Circle()
                .fill(color(for: state))
                .frame(width: 7, height: 7)

            Text(session.folder)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 10)

            // Elapsed time only makes sense for a session that's actually working —
            // an idle/done/asking session has no "current turn" to time, so the
            // column is left blank rather than showing a placeholder dash.
            if showElapsed, state == .working, let elapsed = store.elapsedWorking(for: session) {
                Text(SessionMetrics.formatElapsed(elapsed))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
            } else if showElapsed {
                Color.clear.frame(width: 54, height: 1)
            }

            Text(state.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(highlightBackground(isHighlighted))
        // The highlight is a neutral selection chrome — a tinted fill plus a leading
        // bar — deliberately using no state colour of its own, so it can never be
        // confused with the working/asking/done dot it sits next to.
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .help(session.cwd)
    }

    @ViewBuilder
    private func highlightBackground(_ on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10))
        } else {
            Color.clear
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var usageFooter: some View {
        if let limits = SessionMetrics.shared.limits(),
           limits.fiveHourPercent != nil || limits.sevenDayPercent != nil {
            Divider().padding(.vertical, 6)
            HStack(spacing: 12) {
                if let five = limits.fiveHourPercent {
                    Text("5h \(Int(five))%")
                }
                if let week = limits.sevenDayPercent {
                    Text("7d \(Int(week))%")
                }
                Spacer()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .asking:  return Rig.askingColor
        case .done:    return Rig.doneColor
        case .working: return .accentColor
        case .idle:    return .secondary.opacity(0.5)
        }
    }
}

/// Shared highlight state between the popover view and the key-event monitor in
/// AppDelegate. An ObservableObject rather than @State so the monitor — which lives
/// outside SwiftUI — can drive it.
///
/// Tracks the highlighted session by *id*, not list position. The default sort
/// ("state priority") reorders live as sessions change state — the whole point of
/// the app — so a plain Int index would silently point at a different session the
/// moment anything reordered while the popover was open, including making ⌘↩ jump
/// to the wrong terminal. `orderedIDs` is refreshed by SessionListView on every
/// render, so `move` always operates on the order actually on screen right now.
final class KeyboardNavState: ObservableObject {
    @Published var highlightedID: String?
    var orderedIDs: [String] = []

    func reset() { highlightedID = nil }

    /// ⌘↓ with nothing highlighted starts at the top; ⌘↑ starts at the bottom.
    /// Movement clamps at the ends rather than wrapping, so holding a key can't
    /// silently loop back around.
    func move(down: Bool) {
        guard !orderedIDs.isEmpty else { return }
        guard let current = highlightedID, let idx = orderedIDs.firstIndex(of: current) else {
            highlightedID = down ? orderedIDs.first : orderedIDs.last
            return
        }
        let newIdx = down ? min(idx + 1, orderedIDs.count - 1) : max(idx - 1, 0)
        highlightedID = orderedIDs[newIdx]
    }
}
