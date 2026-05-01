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

      Section("Developer") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Enable Debug Logging", isOn: $settings.debugLogging)
          Text(
            "Emits verbose protocol and connection logs to Console.app for troubleshooting. Leave off for better performance."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
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
