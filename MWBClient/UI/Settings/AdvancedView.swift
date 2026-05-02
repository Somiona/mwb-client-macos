import SwiftUI

struct AdvancedView: View {
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

      Section("Advanced Mouse Settings") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Move mouse relatively", isOn: $settings.moveMouseRelatively)
          Text(
            "Use this option when remote machine's monitor settings are different, or remote machine has multiple monitors"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Block mouse at screen corners", isOn: $settings.blockMouseAtCorners)
          Text("To avoid accident machine-switch at screen corners")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Hide mouse at screen edge", isOn: $settings.hideMouseAtScreenEdge)
          Text(
            "Hide the cursor at the top edge when switching to another machine, and take focus from full-screen apps to ensure keyboard input is redirected"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Disable Easy Mouse when an application is running in full screen",
            isOn: $settings.disableEasyMouseInFullscreen)
          Text(
            "Prevent Easy Mouse from moving to another machine when an application is in full-screen mode"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Security & Power") {
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

      Section("About") {
        HStack {
          Text("Version")
          Spacer()
          if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text(version)
              .foregroundStyle(.secondary)
          } else {
            Text("Unknown")
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          Text("Author")
          Spacer()
          Text("Somiona")
            .foregroundStyle(.secondary)
        }
        HStack {
          Text("GitHub")
          Spacer()
          Button {
            if let url = URL(string: "https://github.com/Somiona/mwb-client-macos") {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Text("github.com/Somiona/mwb-client-macos")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Disclaimer")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            "This project is independent and is not affiliated with or endorsed by Microsoft. It interoperates with the PowerToys Mouse Without Borders protocol by studying the published open-source implementation at microsoft/PowerToys."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Developer") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Enable Debug Logging", isOn: $settings.debugLogging)
          Text(
            "Emits verbose protocol and connection logs to Console.app for troubleshooting. Leave off for better performance."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        LogConsoleView()
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .navigationTitle("Advanced")
  }
}
