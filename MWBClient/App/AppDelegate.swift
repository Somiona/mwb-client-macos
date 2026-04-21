import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Tray Menu Reference

    /// Set by MWBApp after the SwiftUI scene is initialized.
    weak var trayMenu: TrayMenu?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock icon starts hidden (LSUIElement = true in Info.plist).
        // It will be toggled to .regular when the settings window opens.

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

        // Initialize tray menu and auto-connect via MWBApp
        if let app = NSApp.delegate as? MWBApp {
            app.applicationDidFinishLaunching()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Click dock icon -> show settings window
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
        // Bring existing settings window to front, or let SwiftUI create it
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
