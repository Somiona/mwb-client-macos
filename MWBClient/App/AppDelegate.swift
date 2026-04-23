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

        // Set up tray menu and auto-connect
        if let coordinator = Self.sharedCoordinator, let settings = Self.sharedSettings {
            trayMenu = TrayMenu(coordinator: coordinator)

            // Apply initial activation policy based on dock icon setting
            applyActivationPolicy(hideDockIcon: settings.hideDockIcon, windowOpen: false)

            if !settings.windowsIP.isEmpty && !settings.securityKey.isEmpty {
                coordinator.connect()
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
}
