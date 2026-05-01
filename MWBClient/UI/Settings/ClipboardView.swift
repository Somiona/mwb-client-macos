import SwiftUI

struct ClipboardView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Share clipboard", isOn: $settings.syncText)
                        .onChange(of: settings.syncText) {
                            coordinator.clipboardSettingsDidChange()
                        }
                }

                Toggle("Sync images", isOn: $settings.syncImages)
                    .onChange(of: settings.syncImages) {
                        coordinator.clipboardSettingsDidChange()
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Transfer file", isOn: $settings.syncFiles)
                        .onChange(of: settings.syncFiles) {
                            coordinator.clipboardSettingsDidChange()
                        }
                    Text("If a file (<100MB) is copied, it will be transferred to the remote machine clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Synchronization")
            } footer: {
                Text("Choose which clipboard content types to synchronize between your Mac and the Windows machine.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Clipboard")
    }
}
