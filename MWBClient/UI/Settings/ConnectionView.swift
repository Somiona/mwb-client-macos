import ServiceManagement
import SwiftUI

struct ConnectionView: View {
  @Environment(AppCoordinator.self) private var coordinator
  @Environment(SettingsStore.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    Form {
      Section("Connection") {
        HStack {
          TextField("IP Address", text: $settings.windowsIP, prompt: Text("192.168.1.100"))
            .textFieldStyle(.roundedBorder)
            .textContentType(.none)
            .autocorrectionDisabled()
        }

        SecureField("Security Key", text: $settings.securityKey, prompt: Text("Shared secret"))
          .textFieldStyle(.roundedBorder)
          .textContentType(.password)
      }

      Section {
        HStack {
          connectionStatusText

          Spacer()

          connectButton
        }

        if let error = coordinator.errorMessage {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
            Text(error)
              .foregroundStyle(.secondary)
              .font(.caption)
          }
        }
      }

      Section("App Behavior") {
        Toggle("Auto-connect on launch", isOn: $settings.autoConnect)
        Toggle("Start at login", isOn: $settings.startAtLogin)
          .onChange(of: settings.startAtLogin) { _, newValue in
            setLoginItemEnabled(newValue)
          }
        Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
        Toggle("Hide dock icon", isOn: $settings.hideDockIcon)
        Toggle("Check for updates", isOn: $settings.checkForUpdates)
      }

      Section {
        HStack(spacing: 0) {
          Text("If you found a bug or have any suggestions, ")
            .foregroundStyle(.secondary)
          Button {
            if let url = URL(string: "https://github.com/Somiona/mwb-client-macos/issues/new") {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Text("Report an Issue")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
          Text(" on GitHub.")
            .foregroundStyle(.secondary)
          Spacer()
        }

        if settings.checkForUpdates, VersionChecker.shared.isUpdateAvailable,
           let version = VersionChecker.shared.latestVersion {
          HStack(spacing: 0) {
            Image(systemName: "arrow.down.circle.fill")
              .foregroundStyle(.green)
            Text(" Update available: ")
              .foregroundStyle(.secondary)
            Button {
              if let url = VersionChecker.shared.releaseURL {
                NSWorkspace.shared.open(url)
              }
            } label: {
              Text(version)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            Spacer()
          }
        }

        if settings.checkForUpdates, VersionChecker.shared.hasFailed {
          HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
              .foregroundStyle(.orange)
            Text("Version check failed. ")
              .foregroundStyle(.secondary)
            Button {
              VersionChecker.shared.checkIfNeeded()
            } label: {
              Text("Retry")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            Spacer()
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .navigationTitle("Connection")
  }

  private func setLoginItemEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      settings.startAtLogin = !enabled
    }
  }

  // MARK: - Subviews

  private var statusIndicator: some View {
    let isConnected = coordinator.connectionState == .connected
    let isConnecting =
      coordinator.connectionState == .connecting
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
    case .connecting: return "Connecting"
    case .handshaking: return "Handshaking"
    case .connected:
      return coordinator.windowsMachineName.isEmpty
        ? "Connected"
        : "Connected to \(coordinator.windowsMachineName)"
    case .reconnecting: return "Reconnecting"
    }
  }

  private var connectionStatusText: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Status")
        .font(.headline)
      statusIndicator
        .foregroundStyle(.secondary)
        .font(.subheadline)
    }
  }

  private var connectButton: some View {
    let isConnected = coordinator.connectionState == .connected
    let isConnecting =
      coordinator.connectionState == .connecting
      || coordinator.connectionState == .handshaking
      || coordinator.connectionState == .reconnecting

    return Button(isConnected || isConnecting ? "Disconnect" : "Connect") {
      if isConnected || isConnecting {
        Task {
          await coordinator.disconnect()
        }
      } else {
        coordinator.connect()
      }
    }
    .controlSize(.large)
    .buttonStyle(.borderedProminent)
    .disabled(
      !isConnected && !isConnecting
        && (settings.windowsIP.isEmpty || settings.securityKey.isEmpty))
  }
}
