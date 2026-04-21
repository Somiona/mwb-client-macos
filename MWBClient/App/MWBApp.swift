import SwiftUI

@main
struct MWBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let settings: SettingsStore
    private let coordinator: AppCoordinator
    @State private var trayMenu: TrayMenu?

    init() {
        let store = SettingsStore()
        self.settings = store
        self.coordinator = AppCoordinator(settings: store)
    }

    var body: some Scene {
        Window("MWB Client", id: "settings") {
            SettingsWindow()
                .environment(coordinator)
                .environment(settings)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    /// Creates the tray menu and optionally auto-connects.
    ///
    /// Called from `AppDelegate.applicationDidFinishLaunching` so that
    /// `NSApp` and the SwiftUI scene graph are both initialized.
    func applicationDidFinishLaunching() {
        let tray = TrayMenu(coordinator: coordinator)
        trayMenu = tray
        appDelegate.trayMenu = tray

        // Auto-connect if both connection settings are present
        if !settings.windowsIP.isEmpty && !settings.securityKey.isEmpty {
            coordinator.connect()
        }
    }
}
