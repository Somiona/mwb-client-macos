import SwiftUI

struct ClipboardView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Synchronization") {
                Toggle("Sync text", isOn: $settings.syncText)
                    .onChange(of: settings.syncText) {
                        coordinator.clipboardSettingsDidChange()
                    }

                Toggle("Sync images", isOn: $settings.syncImages)
                    .onChange(of: settings.syncImages) {
                        coordinator.clipboardSettingsDidChange()
                    }

                Toggle("Sync files", isOn: $settings.syncFiles)
                    .onChange(of: settings.syncFiles) {
                        coordinator.clipboardSettingsDidChange()
                    }
            }

            Section {
                Text("Choose which clipboard content types to synchronize between your Mac and the Windows machine.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Clipboard")
    }
}
