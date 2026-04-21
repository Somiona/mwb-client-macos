import AppKit

// MARK: - TrayMenu

@MainActor
final class TrayMenu {

    // MARK: - Properties

    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private var observationTask: Task<Void, Never>?

    // MARK: - Menu Item References

    private let statusLabelItem: NSMenuItem
    private let machineNameItem: NSMenuItem
    private let enabledToggleItem: NSMenuItem

    // MARK: - Init

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "cursorarrow.and.square.on.square.dashed",
            accessibilityDescription: "MWB Client"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLabelItem = NSMenuItem()
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)

        machineNameItem = NSMenuItem()
        machineNameItem.isEnabled = false
        machineNameItem.isHidden = true
        menu.addItem(machineNameItem)

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
            title: "Settings...",
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
        observationTask?.cancel()
        observationTask = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Observation

    private func startObserving() {
        scheduleObservation()
    }

    private func scheduleObservation() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }

            withObservationTracking {
                _ = self.coordinator.connectionState
                _ = self.coordinator.windowsMachineName
                _ = self.coordinator.isSharingEnabled
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    updateMenu()
                    // Re-register for the next change
                    scheduleObservation()
                }
            }
        }
    }

    // MARK: - Menu Update

    private func updateMenu() {
        switch coordinator.connectionState {
        case .disconnected:
            statusLabelItem.title = "Status: Disconnected"
            statusItem.button?.image = NSImage(
                systemSymbolName: "cursorarrow.and.square.on.square.dashed",
                accessibilityDescription: "MWB Client"
            )
            machineNameItem.isHidden = true
            enabledToggleItem.title = "Connect"
            enabledToggleItem.state = .off

        case .connecting, .handshaking, .reconnecting:
            let label: String
            switch coordinator.connectionState {
            case .connecting: label = "Connecting..."
            case .handshaking: label = "Handshaking..."
            case .reconnecting: label = "Reconnecting..."
            default: label = "Connecting..."
            }
            statusLabelItem.title = "Status: \(label)"
            statusItem.button?.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "MWB Client"
            )
            machineNameItem.isHidden = true
            enabledToggleItem.title = "Disconnect"
            enabledToggleItem.state = .on

        case .connected:
            statusLabelItem.title = "Status: Connected"
            statusItem.button?.image = NSImage(
                systemSymbolName: "cursorarrow.and.square.on.square",
                accessibilityDescription: "MWB Client"
            )
            if !coordinator.windowsMachineName.isEmpty {
                machineNameItem.title = coordinator.windowsMachineName
                machineNameItem.isHidden = false
            } else {
                machineNameItem.isHidden = true
            }
            enabledToggleItem.title = "Disconnect"
            enabledToggleItem.state = .on
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        switch coordinator.connectionState {
        case .disconnected:
            coordinator.connect()
        case .connected, .connecting, .handshaking, .reconnecting:
            coordinator.disconnect()
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
        coordinator.disconnect()
        NSApp.terminate(nil)
    }
}
