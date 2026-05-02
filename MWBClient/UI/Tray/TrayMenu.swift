import AppKit

// MARK: - TrayMenu

@MainActor
final class TrayMenu {

  // MARK: - Properties

  private let statusItem: NSStatusItem
  private let coordinator: AppCoordinator

  // MARK: - Menu Item References

  private let statusLabelItem: NSMenuItem
  private let machineNameItem: NSMenuItem
  private let enabledToggleItem: NSMenuItem
  private let errorItem: NSMenuItem

  // MARK: - Init

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = TrayMenu.iconForState(.disconnected)

    let menu = NSMenu()
    menu.autoenablesItems = false

    statusLabelItem = NSMenuItem()
    statusLabelItem.isEnabled = false
    menu.addItem(statusLabelItem)

    machineNameItem = NSMenuItem()
    machineNameItem.isEnabled = false
    machineNameItem.isHidden = true
    menu.addItem(machineNameItem)

    errorItem = NSMenuItem()
    errorItem.isEnabled = false
    errorItem.isHidden = true
    menu.addItem(errorItem)

    menu.addItem(.separator())

    enabledToggleItem = NSMenuItem(
      title: "Connect",
      action: #selector(toggleEnabled),
      keyEquivalent: ""
    )
    enabledToggleItem.target = self
    menu.addItem(enabledToggleItem)

    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings",
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit MWB Client",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem.menu = menu

    updateMenu()

    // Observe coordinator state changes via withObservationTracking
    startObserving()
  }

  func tearDown() {
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  // MARK: - Observation

  private func startObserving() {
    scheduleObservation()
  }

  private func scheduleObservation() {
    withObservationTracking {
      _ = self.coordinator.connectionState
      _ = self.coordinator.windowsMachineName
      _ = self.coordinator.isSharingEnabled
      _ = self.coordinator.errorMessage
      _ = self.coordinator.canConnect
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        updateMenu()
        scheduleObservation()
      }
    }
  }

  // MARK: - Menu Update

  private func updateMenu() {
    // Update error item visibility
    if let error = coordinator.errorMessage {
      errorItem.title = "Error: \(error)"
      errorItem.isHidden = false
    } else {
      errorItem.isHidden = true
    }

    switch coordinator.connectionState {
    case .disconnected:
      statusLabelItem.attributedTitle = coloredDotTitle(text: "Disconnected", color: .red)
      statusItem.button?.image = TrayMenu.iconForState(.disconnected)
      machineNameItem.isHidden = true
      let canConnect = coordinator.canConnect
      enabledToggleItem.title = "Connect"
      enabledToggleItem.isEnabled = canConnect
      enabledToggleItem.toolTip =
        canConnect ? nil : "Incomplete setup — please check Settings for details"

    case .connecting, .handshaking, .reconnecting:
      let label: String
      switch coordinator.connectionState {
      case .connecting: label = "Connecting"
      case .handshaking: label = "Handshaking"
      case .reconnecting: label = "Reconnecting"
      default: label = "Connecting"
      }
      statusLabelItem.attributedTitle = coloredDotTitle(text: label, color: .yellow)
      statusItem.button?.image = TrayMenu.iconForState(.connecting)
      machineNameItem.isHidden = true
      enabledToggleItem.title = "Disconnect"
      enabledToggleItem.isEnabled = true

    case .connected:
      statusLabelItem.attributedTitle = coloredDotTitle(text: "Connected", color: .green)
      statusItem.button?.image = TrayMenu.iconForState(.connected)
      if !coordinator.windowsMachineName.isEmpty {
        machineNameItem.title = coordinator.windowsMachineName
        machineNameItem.isHidden = false
      } else {
        machineNameItem.isHidden = true
      }
      enabledToggleItem.title = "Disconnect"
      enabledToggleItem.isEnabled = true
    }
  }

  // MARK: - Actions

  @objc private func toggleEnabled() {
    Task {
      switch coordinator.connectionState {
      case .disconnected:
        if !coordinator.accessibilityGranted {
          InputCapture.showPermissionAlert()
        } else {
          coordinator.connect()
        }
      case .connected, .connecting, .handshaking, .reconnecting:
        await coordinator.disconnect()
      }
    }
  }

  @objc private func openSettings() {
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    NSApp.setActivationPolicy(.regular)
  }

  @objc private func quit() {
    Task {
      await coordinator.quit()
    }
  }

  // MARK: - Tray Icon Assets

  private func coloredDotTitle(text: String, color: NSColor) -> NSAttributedString {
    let attachment = NSTextAttachment()
    let dotImage = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
      color.setFill()
      path.fill()
      return true
    }
    attachment.image = dotImage
    let dotString = NSAttributedString(attachment: attachment)
    let space = NSAttributedString(string: " ")
    let textString = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.menuFont(ofSize: 0)
      ])
    let combined = NSMutableAttributedString()
    combined.append(dotString)
    combined.append(space)
    combined.append(textString)
    return combined
  }

  private enum TrayIconState {
    case disconnected
    case connecting
    case connected
  }

  private static func iconForState(_ state: TrayIconState) -> NSImage {
    let symbolName: String
    switch state {
    case .disconnected:
      symbolName = "cursorarrow.and.square.on.square.dashed"
    case .connecting:
      symbolName = "arrow.triangle.2.circlepath"
    case .connected:
      symbolName = "square.on.square.fill"
    }

    let config = NSImage.SymbolConfiguration(
      pointSize: 14,
      weight: .medium
    )
    guard
      let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MWB Client"),
      let image = baseImage.withSymbolConfiguration(config)
    else {
      return NSImage(
        systemSymbolName: "questionmark.square", accessibilityDescription: "MWB Client")!
    }

    image.isTemplate = true
    return image
  }
}
