import SwiftUI

struct ConnectionView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Windows Machine") {
                HStack {
                    TextField("IP Address", text: $settings.windowsIP, prompt: Text("192.168.1.100"))
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.none)
                        .autocorrectionDisabled()

                    statusIndicator
                }

                SecureField("Security Key", text: $settings.securityKey, prompt: Text("Shared secret"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }

            Section("Ports") {
                HStack {
                    TextField("Input Port", value: $settings.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("Mouse and keyboard forwarding")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    TextField("Clipboard Port", value: $settings.clipboardPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("Clipboard synchronization")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    connectionStatusText

                    Spacer()

                    connectButton
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Connection")
        .onChange(of: settings.windowsIP) {
            coordinator.connectionSettingsDidChange()
        }
        .onChange(of: settings.securityKey) {
            coordinator.connectionSettingsDidChange()
        }
        .onChange(of: settings.port) {
            coordinator.connectionSettingsDidChange()
        }
    }

    // MARK: - Subviews

    private var statusIndicator: some View {
        let isConnected = coordinator.connectionState == .connected
        let isConnecting = coordinator.connectionState == .connecting
            || coordinator.connectionState == .handshaking
            || coordinator.connectionState == .reconnecting

        return HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? .green : isConnecting ? .yellow : .red)
                .frame(width: 10, height: 10)

            Text(statusLabel)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var statusLabel: String {
        switch coordinator.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .handshaking: return "Handshaking..."
        case .connected: return coordinator.windowsMachineName.isEmpty
            ? "Connected"
            : "Connected to \(coordinator.windowsMachineName)"
        case .reconnecting: return "Reconnecting..."
        }
    }

    private var connectionStatusText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Status")
                .font(.headline)
            Text(statusLabel)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
    }

    private var connectButton: some View {
        let isConnected = coordinator.connectionState == .connected
        let isConnecting = coordinator.connectionState == .connecting
            || coordinator.connectionState == .handshaking
            || coordinator.connectionState == .reconnecting

        return Button(isConnected || isConnecting ? "Disconnect" : "Connect") {
            if isConnected || isConnecting {
                coordinator.disconnect()
            } else {
                coordinator.connect()
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!isConnected && !isConnecting
            && (settings.windowsIP.isEmpty || settings.securityKey.isEmpty))
    }
}
