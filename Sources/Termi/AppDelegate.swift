import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SessionStore()
    private let nav = KeyboardNavState()
    private var panel: MascotPanel!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var notifyItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var updateURL: URL?
    private var prefsWindow: NSWindow?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private lazy var focusWatcher = TerminalFocusWatcher(store: store)

    /// Set by the menu bar toggle; when hidden, the panel stays down regardless of state.
    private var userHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = MascotPanel { [store] in
            MascotView(store: store)
        }
        panel.onClick = { [weak self] in self?.handleClick() }
        panel.isLocked = MascotSettings.positionLocked

        buildStatusItem()
        buildPopover()

        // Panel visibility follows the aggregate state: no sessions, no mascot.
        store.$displayState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyVisibility(state) }
            .store(in: &cancellables)

        store.onAlert = { session in Notifier.shared.alert(session) }
        if MascotSettings.notificationsEnabled { Notifier.shared.requestAuthorizationIfPossible() }
        store.start()
        focusWatcher.start()

        checkForUpdate()

        NotificationCenter.default.addObserver(
            forName: .termiCheckForUpdatesNow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkForUpdate(force: true)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel.clampToVisibleScreen()
        }
    }

    // MARK: - Visibility

    private func applyVisibility(_ state: MascotDisplayState) {
        let shouldShow = (state != .none) && !userHidden
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            if panel.isVisible {
                closePopover()
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - Popover

    private func buildPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(store: store, nav: nav)
        )
    }

    private func handleClick() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    private func showPopover() {
        guard let content = panel.contentView else { return }
        nav.reset()
        // Key (but non-activating) so the popover receives events without pulling
        // focus out of whatever app you were typing in.
        panel.makeKeyAndOrderFront(nil)
        popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        installKeyMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeKeyMonitor()
        nav.reset()
    }

    // MARK: - Keyboard navigation
    //
    // A local event monitor rather than SwiftUI key handling: the popover is hosted
    // by a non-activating panel, so it never becomes first responder in the usual way.

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown,
                  event.modifierFlags.contains(.command)
            else { return event }

            switch event.keyCode {
            case 125: self.nav.move(down: true);  return nil   // ↓
            case 126: self.nav.move(down: false); return nil   // ↑
            case 36, 76:                                        // ↩ / numpad ↩
                self.openHighlighted()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func openHighlighted() {
        guard let id = nav.highlightedID,
              let session = store.sortedSessions().first(where: { $0.id == id })
        else { return }
        TerminalFocusWatcher.focus(session: session)
        closePopover()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "apple.terminal", accessibilityDescription: "Termi"
        )
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show / Hide Mascot",
                     action: #selector(toggleMascot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Position",
                     action: #selector(resetPosition), keyEquivalent: "").target = self
        lockItem = menu.addItem(withTitle: "Lock Position",
                                action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self

        let sizeItem = NSMenuItem()
        let sizeHost = NSHostingView(rootView: MascotSizeControl(
            onBegin: { [weak self] in self?.panel.beginResize() },
            onChange: { [weak self] newScale in
                MascotSettings.scale = newScale
                self?.panel.setScale(newScale)
            },
            onEnd: { [weak self] in self?.panel.endResize() }
        ))
        sizeHost.frame = NSRect(x: 0, y: 0, width: 230, height: 54)
        sizeItem.view = sizeHost
        menu.addItem(sizeItem)

        menu.addItem(.separator())

        // Hidden until UpdateChecker actually finds a newer release; title is
        // a placeholder until then.
        updateItem = menu.addItem(withTitle: "Update available",
                                  action: #selector(openUpdatePage), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true

        menu.addItem(withTitle: "Preferences…",
                     action: #selector(openPreferences), keyEquivalent: ",").target = self
        soundItem = menu.addItem(withTitle: "Play Sounds",
                                 action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        notifyItem = menu.addItem(withTitle: "Desktop Notifications",
                                  action: #selector(toggleNotifications), keyEquivalent: "")
        notifyItem.target = self
        loginItem = menu.addItem(withTitle: "Start at Login",
                                 action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Termi",
                     action: #selector(quit), keyEquivalent: "q").target = self

        // No "About Termi" panel exists — accessory apps have no application
        // menu bar, so this disabled line is the only place the installed
        // version is visible without leaving the app.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let versionItem = menu.addItem(withTitle: "Termi v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false

        statusItem.menu = menu
    }

    private func checkForUpdate(force: Bool = false) {
        UpdateChecker.checkForUpdate(force: force) { [weak self] version, url in
            guard let self else { return }
            self.updateURL = url
            self.updateItem.title = "Update available (\(version))"
            self.updateItem.isHidden = false
        }
    }

    @objc private func openUpdatePage() {
        guard let updateURL else { return }
        NSWorkspace.shared.open(updateURL)
    }

    @objc private func openPreferences() {
        if let w = prefsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Termi Preferences"
        window.contentViewController = NSHostingController(rootView: PreferencesView(store: store))
        window.isReleasedWhenClosed = false
        window.center()
        prefsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLock() {
        MascotSettings.positionLocked.toggle()
        panel.isLocked = MascotSettings.positionLocked
    }

    @objc private func toggleSound() {
        Notifier.shared.soundEnabled.toggle()
        NotificationCenter.default.post(name: .termiSoundSettingChanged, object: nil)
    }

    @objc private func toggleNotifications() {
        MascotSettings.notificationsEnabled.toggle()
        if MascotSettings.notificationsEnabled { Notifier.shared.requestAuthorizationIfPossible() }
        NotificationCenter.default.post(name: .termiSoundSettingChanged, object: nil)
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func toggleMascot() {
        userHidden.toggle()
        applyVisibility(store.displayState)
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "mascotOrigin")
        panel.moveToDefaultCorner()
        panel.saveOrigin()
        if !userHidden, store.displayState != .none { panel.orderFrontRegardless() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// Checkmarks are refreshed as the menu opens, so they always reflect current settings.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = LoginItem.isEnabled ? .on : .off
        lockItem?.state = MascotSettings.positionLocked ? .on : .off
        soundItem?.state = Notifier.shared.soundEnabled ? .on : .off
        notifyItem?.state = MascotSettings.notificationsEnabled ? .on : .off
    }
}
