import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock icon starts hidden (LSUIElement = true in Info.plist)
        // Will be toggled to .regular when settings window opens
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Click dock icon -> show settings window (when dock icon is visible)
        return true
    }
}
