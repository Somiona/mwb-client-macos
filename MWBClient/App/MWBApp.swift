import SwiftUI

@main
struct MWBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let settings: SettingsStore
    private let coordinator: AppCoordinator

    init() {
        let store = SettingsStore()
        let coord = AppCoordinator(settings: store)
        self.settings = store
        self.coordinator = coord
        AppDelegate.sharedCoordinator = coord
        AppDelegate.sharedSettings = store
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
}
