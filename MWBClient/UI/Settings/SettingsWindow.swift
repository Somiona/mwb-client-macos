import SwiftUI

struct SettingsWindow: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPage) {
                Label("Connection", systemImage: "link")
                    .tag(SettingsPage.connection)
                Label("Screen Layout", systemImage: "display")
                    .tag(SettingsPage.layout)
                Label("Clipboard", systemImage: "doc.on.doc")
                    .tag(SettingsPage.clipboard)
                Label("General", systemImage: "gear")
                    .tag(SettingsPage.general)
                Label("Permissions", systemImage: "lock.shield")
                    .tag(SettingsPage.permissions)
            }
            .navigationTitle("MWB Client")
            .listStyle(.sidebar)
        } detail: {
            switch selectedPage {
            case .connection:
                ConnectionView()
            case .layout:
                LayoutView()
            case .clipboard:
                ClipboardView()
            case .general:
                GeneralView()
            case .permissions:
                PermissionsView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    @State private var selectedPage: SettingsPage = .connection
}

enum SettingsPage: Hashable {
    case connection
    case layout
    case clipboard
    case general
    case permissions
}
