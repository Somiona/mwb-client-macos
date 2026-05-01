import AppKit
import SwiftUI

struct PermissionsView: View {
    @Environment(SettingsStore.self) private var settings

    private var accessibilityGranted: Bool {
        InputCapture.hasAccessibilityPermission()
    }

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording and Input Monitoring")
                            .font(.headline)

                        Text("MWB Client needs Accessibility permission to capture mouse and keyboard events for forwarding to the Windows machine.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(accessibilityGranted ? .green : .red)
                            .frame(width: 10, height: 10)

                        Text(accessibilityGranted ? "Granted" : "Not Granted")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if !accessibilityGranted {
                    Button("Open System Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section {
                Text("MWB Client uses Accessibility permissions to monitor input events. This is required for cursor crossing and keyboard forwarding to work correctly. No input data is stored or transmitted outside your local network.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Security & Power") {
                @Bindable var settings = settings
                
                Toggle("Same Subnet Only", isOn: $settings.sameSubnetOnly)
                Text("Only allow connections from machines on the same local subnet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Validate Remote IP (DNS)", isOn: $settings.validateRemoteIP)
                Text("Perform reverse DNS lookup to verify the remote machine's hostname.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Block Remote Screen Saver", isOn: $settings.blockScreenSaver)
                Text("Periodically send 'Awake' packets to prevent the remote screen from sleeping while you are active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Permissions")
        .onAppear {
            // Force re-evaluation when the view appears
            // (user may have just granted permission in System Settings)
        }
    }
}
