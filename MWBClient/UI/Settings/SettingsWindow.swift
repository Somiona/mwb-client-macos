import SwiftUI

struct SettingsWindow: View {
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
                Text("Connection")
            case .layout:
                Text("Screen Layout")
            case .clipboard:
                Text("Clipboard")
            case .general:
                Text("General")
            case .permissions:
                Text("Permissions")
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
