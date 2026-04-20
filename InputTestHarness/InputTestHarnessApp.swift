import SwiftUI

@main
struct InputTestHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            TestHarnessView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 520)
    }
}
