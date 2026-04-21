import AppKit

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
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard isSettingsWindow(notification.object as? NSWindow) else { return }
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
