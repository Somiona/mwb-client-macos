import AppKit
import Foundation
import os.log

// MARK: - AppCoordinator

@MainActor
@Observable
final class AppCoordinator {

    // MARK: - Published State (observed by SwiftUI views)

    /// Current connection state to the Windows machine.
    private(set) var connectionState: ConnectionState = .disconnected

    /// Name of the connected Windows machine (received via heartbeatEx).
    private(set) var windowsMachineName: String = ""

    /// Local machine name shown to the remote machine.
    var localMachineName: String {
        settings.machineName
    }

    /// Whether input forwarding (cursor crossing) is enabled.
    private(set) var isSharingEnabled: Bool = false

    /// Whether the Accessibility permission has been granted.
    var accessibilityGranted: Bool {
        InputCapture.hasAccessibilityPermission()
    }

    /// Human-readable error message for the current failure state, if any.
    /// Observed by UI to display error banners. Set to nil on successful connection.
    private(set) var errorMessage: String?

    // MARK: - Subsystem References

    private let settings: SettingsStore

    private var networkManager: NetworkManager?
    private var serverListener: ServerListener?
    private var heartbeatService: HeartbeatService?
    private var clipboardManager: ClipboardManager?

    private let inputCapture = InputCapture()
    private let inputInjection = InputInjection()
    private let edgeDetector = EdgeDetector()

    // MARK: - Crossing State

    /// Whether the cursor is currently on the remote machine.
    private var isCrossingActive = false

    /// The machine ID assigned by the Windows machine during handshake.
    private var localMachineID: UInt32 = 0

    // MARK: - State Polling

    private var statePollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    // MARK: - Init

    init(settings: SettingsStore) {
        self.settings = settings
        wireEdgeDetector()
        wireInputCapture()
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard connectionState == .disconnected else { return }

        let logIP = settings.windowsIP
        let logPort = settings.port
        Logger.coordinator.info("Connecting to Windows machine at \(logIP):\(logPort)")

        let host = settings.windowsIP
        let securityKey = settings.securityKey
        let port = UInt16(settings.port)
        let clipboardPort = UInt16(settings.clipboardPort)
        let machineName = settings.machineName
        let screenSize = ScreenInfo.mainScreenSizeUInt16

        // --- Create subsystems ---

        let nm = NetworkManager(
            host: host,
            port: port,
            securityKey: securityKey,
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height
        )

        let hb = HeartbeatService(
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height
        )

        let cm = ClipboardManager(
            host: host,
            port: clipboardPort,
            securityKey: securityKey,
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height,
            syncText: settings.syncText,
            syncImages: settings.syncImages,
            syncFiles: settings.syncFiles
        )

        let sl = ServerListener(
            port: port,
            securityKey: securityKey,
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height
        )

        networkManager = nm
        heartbeatService = hb
        clipboardManager = cm
        serverListener = sl

        // --- Edge detector configuration ---
        edgeDetector.crossingEdge = settings.crossingEdge

        // --- Start input capture ---
        let captureStarted = inputCapture.start()

        // --- Wire callbacks and start subsystems on actor contexts ---
        connectTask = Task { [weak self] in
            guard let self else { return }

            // Wire NetworkManager callbacks
            await nm.setCallbacks(
                onMouse: { [weak self] mouseData in
                    Task { @MainActor [weak self] in
                        self?.handleRemoteMouse(mouseData)
                    }
                },
                onKeyboard: { [weak self] keyData in
                    Task { @MainActor [weak self] in
                        self?.handleRemoteKeyboard(keyData)
                    }
                },
                onClipboard: nil
            )

            // Bind HeartbeatService to NetworkManager
            await hb.bind(networkManager: nm)

            // Wire ServerListener callbacks
            await sl.setCallbacks(
                onMouse: { [weak self] mouseData in
                    Task { @MainActor [weak self] in
                        self?.handleRemoteMouse(mouseData)
                    }
                },
                onKeyboard: { [weak self] keyData in
                    Task { @MainActor [weak self] in
                        self?.handleRemoteKeyboard(keyData)
                    }
                },
                onClipboard: nil
            )

            // Connect to Windows machine
            await nm.connect()

            // Once connected, start remaining services
            await self.startServicesAfterConnection(nm: nm, hb: hb, cm: cm, sl: sl)
        }

        // Start state polling to observe NetworkManager state changes
        startStatePolling(nm: nm)

        connectionState = .connecting
        isSharingEnabled = captureStarted

        if !captureStarted {
            Logger.coordinator.warning("Input capture not started (accessibility permission may be missing)")
        }
    }

    func disconnect() {
        Logger.coordinator.info("Disconnecting")
        errorMessage = nil
        statePollTask?.cancel()
        statePollTask = nil
        connectTask?.cancel()
        connectTask = nil

        let nm = networkManager
        let sl = serverListener
        let hb = heartbeatService
        let cm = clipboardManager

        networkManager = nil
        serverListener = nil
        heartbeatService = nil
        clipboardManager = nil

        Task {
            await nm?.disconnect()
            await sl?.stop()
            await hb?.stop()
            await cm?.stop()
        }

        inputCapture.stop()
        inputCapture.crossingActive = false
        edgeDetector.reset()
        inputInjection.reset()

        isCrossingActive = false
        isSharingEnabled = false
        connectionState = .disconnected
        windowsMachineName = ""
    }

    // MARK: - Settings Observation

    /// Call when connection-related settings change (IP, security key, port).
    /// Disconnects and reconnects with new settings.
    func connectionSettingsDidChange() {
        let wasConnected = connectionState != .disconnected
        disconnect()
        if wasConnected && !settings.windowsIP.isEmpty && !settings.securityKey.isEmpty {
            connect()
        }
    }

    /// Call when clipboard sync settings change.
    func clipboardSettingsDidChange() {
        Task {
            await clipboardManager?.updateSyncSettings(
                syncText: settings.syncText,
                syncImages: settings.syncImages,
                syncFiles: settings.syncFiles
            )
        }
    }

    /// Call when the crossing edge setting changes.
    func crossingEdgeDidChange() {
        edgeDetector.crossingEdge = settings.crossingEdge
    }

    // MARK: - Post-Connection Startup

    private func startServicesAfterConnection(
        nm: NetworkManager,
        hb: HeartbeatService,
        cm: ClipboardManager,
        sl: ServerListener
    ) async {
        // Wait for the connection to reach .connected state
        while true {
            guard !Task.isCancelled else { return }
            let state = await nm.state
            if state == .connected {
                break
            }
            if state == .disconnected {
                // Connection failed
                return
            }
            do {
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            } catch {
                return
            }
        }

        // Extract handshake results
        let machineID = await nm.machineID
        let connectedName = await nm.connectedMachineName
        localMachineID = machineID
        windowsMachineName = connectedName

        // Configure and start heartbeat
        await hb.configure(magicHash: 0, machineID: machineID)
        await hb.start()

        // Start clipboard manager
        await cm.start()

        // Start server listener (so Windows can connect back to us)
        await sl.start()

        connectionState = .connected
        errorMessage = nil
        Logger.coordinator.info("All services started, connected to \(connectedName)")
    }

    // MARK: - State Polling

    private func startStatePolling(nm: NetworkManager) {
        statePollTask?.cancel()
        statePollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000) // 250ms
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }

                let state = await nm.state
                let name = await nm.connectedMachineName
                let reason = await nm.failureReason

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.connectionState = state
                    if !name.isEmpty {
                        self.windowsMachineName = name
                    }
                    // Propagate error messages from NetworkManager
                    if case .reconnecting = state {
                        self.errorMessage = self.describeFailureReason(reason)
                    } else if case .disconnected = state, case .none = reason {
                        self.errorMessage = nil
                    } else if case .disconnected = state {
                        self.errorMessage = self.describeFailureReason(reason)
                    } else if case .connected = state {
                        self.errorMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - Error Messages

    /// Returns a user-facing error message for the given connection failure reason.
    private func describeFailureReason(_ reason: ConnectionFailureReason) -> String? {
        switch reason {
        case .none:
            return nil
        case .connectionRefused:
            return "Connection refused. Check that the Windows machine is running Mouse Without Borders and the IP/port are correct."
        case .timeout:
            return "Connection timed out. Check your network connection and that the Windows machine is reachable."
        case .handshakeFailed:
            return "Handshake failed. Verify that the security key matches on both machines."
        case .hostUnreachable:
            return "Host unreachable. Check that the IP address is correct and the Windows machine is on the same network."
        case .cancelled:
            return nil
        case .unknown(let message):
            return "Connection error: \(message)"
        }
    }

    // MARK: - Event Wiring: Input Capture -> Edge Detection -> Forwarding

    private func wireInputCapture() {
        // Handle accessibility permission revocation
        inputCapture.onPermissionRevoked = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Logger.coordinator.error("Accessibility permission revoked mid-session")
                self.errorMessage = "Accessibility permission was revoked. Input capture has been stopped. Please re-grant permission in System Settings."
                self.isSharingEnabled = false
            }
        }

        // Forward mouse events when crossing is active
        inputCapture.onMouseEvent = { [weak self] mouseData in
            Task { @MainActor [weak self] in
                guard let self, self.isCrossingActive else { return }
                await self.forwardMouseToRemote(mouseData)
            }
        }

        // Forward keyboard events when crossing is active
        inputCapture.onKeyboardEvent = { [weak self] keyData in
            Task { @MainActor [weak self] in
                guard let self, self.isCrossingActive else { return }
                await self.forwardKeyboardToRemote(keyData)
            }
        }

        // Feed mouse position to edge detector
        inputCapture.onMousePosition = { [weak self] mouseData, screenPoint in
            Task { @MainActor [weak self] in
                self?.edgeDetector.updateCursorPosition(mouseData, screenPoint: screenPoint)
            }
        }
    }

    private func wireEdgeDetector() {
        edgeDetector.crossingStart = { [weak self] info in
            Task { @MainActor [weak self] in
                self?.handleCrossingStart(info)
            }
        }
    }

    // MARK: - Crossing Handlers

    private func handleCrossingStart(_ info: CrossingStartInfo) {
        guard !isCrossingActive else { return }

        Logger.coordinator.info("Crossing started at \(info.edge.rawValue) edge")
        isCrossingActive = true
        inputCapture.crossingActive = true
        inputInjection.reset()
    }

    private func handleRemoteMouse(_ data: MouseData) {
        guard connectionState == .connected else { return }

        // First mouse event from Windows means cursor is returning
        if isCrossingActive {
            endCrossing()
        }

        inputInjection.injectMouse(data)
    }

    private func handleRemoteKeyboard(_ data: KeyboardData) {
        guard connectionState == .connected else { return }
        inputInjection.injectKeyboard(data)
    }

    // MARK: - Forwarding to Remote

    private func forwardMouseToRemote(_ data: MouseData) async {
        guard let nm = networkManager else { return }

        var packet = MWBPacket()
        packet.type = PackageType.mouse.rawValue
        packet.src = localMachineID
        packet.des = MWBConstants.broadcastDestination
        data.write(to: &packet)

        await nm.sendPacket(packet)
    }

    private func forwardKeyboardToRemote(_ data: KeyboardData) async {
        guard let nm = networkManager else { return }

        var packet = MWBPacket()
        packet.type = PackageType.keyboard.rawValue
        packet.src = localMachineID
        packet.des = MWBConstants.broadcastDestination
        data.write(to: &packet)

        await nm.sendPacket(packet)
    }

    // MARK: - Crossing End

    private func endCrossing() {
        Logger.coordinator.info("Crossing ended")
        isCrossingActive = false
        inputCapture.crossingActive = false
        edgeDetector.crossingDidEnd()
    }
}
