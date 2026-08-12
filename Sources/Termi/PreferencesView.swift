import SwiftUI

/// "Play Sounds" and "Desktop Notifications" toggle from the menu bar, not here —
/// posted so this window's Volume/Sounds sections stay correctly enabled/disabled
/// even if toggled from the menu while Preferences is already open.
extension Notification.Name {
    static let termiSoundSettingChanged = Notification.Name("termiSoundSettingChanged")
}

/// All settings live here rather than in the menu bar menu — there are now far more
/// of them than a menu can hold comfortably.
struct PreferencesView: View {
    @ObservedObject var store: SessionStore

    // Local mirrors of the persisted settings so the controls stay responsive; each
    // setter writes straight through to MascotSettings.
    @State private var showElapsed = MascotSettings.showElapsedTime
    @State private var showUsage = MascotSettings.showUsageLimit
    @State private var sortMode = MascotSettings.sortMode
    @State private var soundOn = Notifier.shared.soundEnabled
    @State private var volume = MascotSettings.volume
    @State private var askingSound = MascotSettings.askingSound
    @State private var doneSound = MascotSettings.doneSound
    @State private var customOrder = MascotSettings.customOrder

    var body: some View {
        TabView {
            popoverTab.tabItem { Label("Popup", systemImage: "list.bullet") }
            soundTab.tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(width: 430, height: 400)
        .onReceive(NotificationCenter.default.publisher(for: .termiSoundSettingChanged)) { _ in
            soundOn = Notifier.shared.soundEnabled
        }
    }

    // MARK: - Popup

    private var popoverTab: some View {
        Form {
            Section("Show in list") {
                Toggle("Elapsed time on current turn", isOn: $showElapsed)
                    .onChange(of: showElapsed) { MascotSettings.showElapsedTime = showElapsed }
                if showElapsed {
                    Text("Only shown for sessions actually working — idle, asking, and finished sessions leave this blank.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Usage limit %", isOn: $showUsage)
                    .onChange(of: showUsage) { MascotSettings.showUsageLimit = showUsage }
                if showUsage {
                    Text("Reads from your statusline. Run install-statusline.sh once if the footer stays empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Order") {
                Picker("Sort by:", selection: $sortMode) {
                    ForEach(SessionSortMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .onChange(of: sortMode) { MascotSettings.sortMode = sortMode }

                if sortMode == .custom { customOrderEditor }
            }
        }
        .formStyle(.grouped)
    }

    /// Drag-to-reorder lives here rather than in the popover itself, so dragging a
    /// row can never be confused with clicking one to jump to its terminal.
    /// Entries are folders, not sessions — see MascotSettings.customOrder.
    private var customOrderEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag to reorder. Folders not listed appear last.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(orderedFolders(), id: \.self) { cwd in
                    Text((cwd as NSString).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                }
                .onMove { indices, newOffset in
                    var list = orderedFolders()
                    list.move(fromOffsets: indices, toOffset: newOffset)
                    customOrder = list
                    MascotSettings.customOrder = list
                }
            }
            // Sized to show every currently open session without scrolling, up to
            // a cap — below that cap, a fixed height either clipped rows (a closed
            // session's stale entry pushing a real one out of view, with no obvious
            // affordance that the list even scrolls) or left dead space for nothing.
            .frame(height: customOrderListHeight)
        }
    }

    private var customOrderListHeight: CGFloat {
        let rowHeight: CGFloat = 24
        let rows = max(orderedFolders().count, 1)
        return min(CGFloat(rows) * rowHeight, 200)
    }

    /// Saved order first, then any currently-open folder not yet in it. Folders
    /// belonging to a session that's since closed are dropped here — the saved
    /// position for them still lives in MascotSettings.customOrder untouched, so
    /// it's honored again if that folder's session reopens, but a closed session
    /// has no business occupying a visible row (or, worse, silently pushing an
    /// actually-open session out of the visible list).
    private func orderedFolders() -> [String] {
        let open = store.sessions.map(\.cwd)
        var list = customOrder.filter { open.contains($0) }
        for cwd in open where !list.contains(cwd) { list.append(cwd) }
        return list
    }

    // MARK: - Alerts

    private var soundTab: some View {
        Form {
            Section("Volume") {
                HStack(spacing: 10) {
                    Image(systemName: volumeIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Slider(value: $volume, in: 0...1, step: MascotSettings.volumeStep)
                        .onChange(of: volume) { MascotSettings.volume = volume }
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(!soundOn)
            }

            Section("Sounds") {
                SoundPickerRow(title: "Needs you", selection: $askingSound, volume: volume) {
                    MascotSettings.askingSound = askingSound
                }
                SoundPickerRow(title: "Finished", selection: $doneSound, volume: volume) {
                    MascotSettings.doneSound = doneSound
                }
                Text("Click a sound's name to select it, or the ▶ icon to just preview it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!soundOn)
        }
        .formStyle(.grouped)
    }

    /// Icon reflects the level so it's informative rather than decorative —
    /// mirrors how volume controls read elsewhere on macOS.
    private var volumeIcon: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.4 { return "speaker.wave.1.fill" }
        if volume < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
