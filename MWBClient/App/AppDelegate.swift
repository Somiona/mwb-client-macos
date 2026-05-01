import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Shared References

    /// Set by MWBApp.init() before the delegate methods fire.
    nonisolated(unsafe) static weak var sharedCoordinator: AppCoordinator?
    nonisolated(unsafe) static weak var sharedSettings: SettingsStore?

    // MARK: - State

    private var trayMenu: TrayMenu?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe window lifecycle for dock icon toggle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)

        // Set up tray menu and auto-connect
        if let coordinator = Self.sharedCoordinator, let settings = Self.sharedSettings {
            trayMenu = TrayMenu(coordinator: coordinator)

            // Apply initial activation policy based on dock icon setting
            applyActivationPolicy(hideDockIcon: settings.hideDockIcon, windowOpen: false)

            if !settings.windowsIP.isEmpty && !settings.securityKey.isEmpty {
                // Only start services if not running in a test environment
                let isTesting = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_TESTS"] != nil || NSClassFromString("XCTestCase") != nil
                if !isTesting {
                    coordinator.connect()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openSettingsWindow()
        }
        return true
    }

    // MARK: - Window Notifications

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard isSettingsWindow(notification.object as? NSWindow) else { return }
        guard let settings = Self.sharedSettings, !settings.hideDockIcon else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard isSettingsWindow(notification.object as? NSWindow) else { return }
        guard let settings = Self.sharedSettings, !settings.hideDockIcon else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - OS Sleep / Wake

    @objc private func handleSleep() {
        guard let coordinator = Self.sharedCoordinator else { return }
        Task { await coordinator.handleSleep() }
    }

    @objc private func handleWake() {
        guard let coordinator = Self.sharedCoordinator else { return }
        coordinator.handleWake()
    }

    // MARK: - Helpers

    private func isSettingsWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == "settings"
    }

    private func openSettingsWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        guard let settings = Self.sharedSettings, !settings.hideDockIcon else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Activation Policy

    /// Sets the app's activation policy based on the dock icon preference.
    ///
    /// - When `hideDockIcon` is `true`, the app always runs as `.accessory` (no dock icon).
    /// - When `hideDockIcon` is `false` and a window is open, the app runs as `.regular` (dock icon visible).
    /// - When `hideDockIcon` is `false` and no window is open, the app runs as `.accessory` to keep the dock clean.
    @MainActor
    private func applyActivationPolicy(hideDockIcon: Bool, windowOpen: Bool) {
        if hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else if windowOpen {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // This method is called when the user quits from the Dock or via Cmd+Q.
        // If we haven't already performed a graceful quit, try to do it now.
        // Note: Task in willTerminate is risky if it outlives the exit, 
        // but NSApp.terminate() from within coordinator.quit() is safe.
        if let coordinator = Self.sharedCoordinator, coordinator.connectionState == .connected {
            // We use a short timeout here to avoid hanging the OS logout/shutdown
            let task = Task {
                await coordinator.quit()
            }
            // Give it 500ms to send the packet
            Thread.sleep(forTimeInterval: 0.5)
            task.cancel()
        }
    }
}
