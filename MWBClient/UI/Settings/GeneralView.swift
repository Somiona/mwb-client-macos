import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Machine") {
                HStack {
                    TextField("Machine Name", text: $settings.machineName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                }

                Text("This name is displayed to the connected Windows machine.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Startup") {
                Toggle("Start at login", isOn: $settings.startAtLogin)
                    .onChange(of: settings.startAtLogin) { _, newValue in
                        setLoginItemEnabled(newValue)
                    }
            }

            Section("Menu Bar") {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            }

            Section("Dock") {
                Toggle("Hide dock icon", isOn: $settings.hideDockIcon)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("General")
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure so it stays in sync with the system state.
            settings.startAtLogin = !enabled
        }
    }
}
