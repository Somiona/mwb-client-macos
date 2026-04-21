import SwiftUI

@main
struct MWBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let settings: SettingsStore
    private let coordinator: AppCoordinator

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
}
