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
            }

            Section("Menu Bar") {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("General")
    }
}
