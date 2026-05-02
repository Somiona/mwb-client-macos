import SwiftUI

struct SettingsWindow: View {
  @Environment(AppCoordinator.self) private var coordinator

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedPage) {
        Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
          .tag(SettingsPage.connection)
        Label("Screen Layout", systemImage: "rectangle.split.2x1")
          .tag(SettingsPage.layout)
        Label("Clipboard", systemImage: "clipboard")
          .tag(SettingsPage.clipboard)
        Label("Permissions", systemImage: "lock.shield")
          .tag(SettingsPage.permissions)
        Label("Advanced", systemImage: "gearshape")
          .tag(SettingsPage.advanced)
      }
      .navigationTitle("MWB Client")
      .listStyle(.sidebar)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 4) {
          HStack(spacing: 6) {
            Spacer()
            Circle()
              .fill(connectionColor)
              .frame(width: 10, height: 10)
            Text(statusLabel)
              .foregroundStyle(.secondary)
              .font(.subheadline)
            Spacer()
          }
          if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text("version: \(version)")
              .foregroundStyle(.tertiary)
              .font(.caption)
          }
        }
        .padding(.bottom, 8)
      }
    } detail: {
      switch selectedPage {
      case .connection:
        ConnectionView()
      case .layout:
        LayoutView()
      case .clipboard:
        ClipboardView()
      case .permissions:
        PermissionsView()
      case .advanced:
        AdvancedView()
      case nil:
        ConnectionView()
      }
    }
    .frame(minWidth: 600, minHeight: 400)
  }

  @State private var selectedPage: SettingsPage? = .connection

  private var connectionColor: Color {
    switch coordinator.connectionState {
    case .connected: return .green
    case .connecting, .handshaking, .reconnecting: return .yellow
    case .disconnected: return .red
    }
  }

  private var statusLabel: String {
    switch coordinator.connectionState {
    case .disconnected: return "Disconnected"
    case .connecting: return "Connecting"
    case .handshaking: return "Handshaking"
    case .connected: return "Connected"
    case .reconnecting: return "Reconnecting"
    }
  }
}

enum SettingsPage: Hashable {
  case connection
  case layout
  case clipboard
  case permissions
  case advanced
}
