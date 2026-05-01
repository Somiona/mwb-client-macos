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
    private var localMachineID: MachineID = .none

    // MARK: - Reconnection Tracking

    /// Tracks whether we have completed the first connection and subsystem startup.
    /// The state observer skips `restartSubsystems()` while this is true, because
    /// `startServicesAfterConnection()` already handles the initial startup.
    /// Set to false after the first `.connected` emission is processed.
    private var isInitialConnection = true

    // MARK: - State Observation

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
        Logger.coordinator.info("Connecting to Windows machine at \(logIP):\(MWBConstants.inputPort)")

        let host = settings.windowsIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let securityKey = settings.securityKey
        let machineID = MachineID(rawValue: settings.machineID)
        let port = MWBConstants.inputPort
        let machineName = settings.machineName
        let screenSize = ScreenInfo.mainScreenSizeUInt16

        // --- Create subsystems ---

        let nm = NetworkManager(
            host: host,
            port: port,
            securityKey: securityKey,
            machineID: machineID,
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height
        )

        let cm = ClipboardManager(
            machineID: machineID,
            syncText: settings.syncText,
            syncImages: settings.syncImages,
            syncFiles: settings.syncFiles
        )

        let sl = ServerListener(
            port: port,
            securityKey: securityKey,
            machineID: machineID,
            machineName: machineName,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height
        )

        networkManager = nm
        clipboardManager = cm
        serverListener = sl

        // Wire clipboard manager to send via network manager
        Task {
            await cm.setSendPacketCallback { [weak nm] packet in
                await nm?.sendPacket(packet)
            }
        }

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
                onClipboard: { [weak cm] packet in
                    Task {
                        await cm?.handleIncomingPacket(packet)
                    }
                },
                onNextMachine: { [weak self] machineID, x, y in
                    Task { @MainActor [weak self] in
                        self?.handleNextMachine(machineID: machineID, x: x, y: y)
                    }
                }
            )

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
                onClipboard: { [weak cm] packet in
                    Task {
                        await cm?.handleIncomingPacket(packet)
                    }
                }
            )

            // Connect to Windows machine
            await nm.connect()

            // Once connected, start remaining services
            await self.startServicesAfterConnection(nm: nm, cm: cm, sl: sl)
        }

        // Start observing state changes via AsyncStream
        startObservingState(nm: nm)

        connectionState = .connecting
        isSharingEnabled = captureStarted

        if !captureStarted {
            Logger.coordinator.warning("Input capture not started (accessibility permission may be missing)")
        }
    }

    /// Gracefully disconnects from the remote machine, sending a ByeBye signal.
    func disconnect() async {
        Logger.coordinator.info("Disconnecting")
        
        // 1. Send ByeBye signal to remote if connected
        if let nm = networkManager {
            await nm.sendByeBye()
            await nm.disconnect()
        }
        
        // 2. Send ByeBye signal to all inbound connections
        if let sl = serverListener {
            await sl.sendByeBye()
            await sl.stop()
        }
        
        // 3. Clean up other subsystems
        if let hb = heartbeatService { await hb.stop() }
        if let cm = clipboardManager { await cm.stop() }
        
        // 4. Clean up local state
        errorMessage = nil
        statePollTask?.cancel()
        statePollTask = nil
        connectTask?.cancel()
        connectTask = nil

        networkManager = nil
        serverListener = nil
        heartbeatService = nil
        clipboardManager = nil

        inputCapture.stop()
        inputCapture.crossingActive = false
        edgeDetector.reset()
        inputInjection.reset()

        isCrossingActive = false
        isSharingEnabled = false
        connectionState = .disconnected
        windowsMachineName = ""
        isInitialConnection = true
    }

    /// Performs a graceful shutdown, sending a ByeBye packet before disconnecting.
    func quit() async {
        Logger.coordinator.info("Graceful quit requested")
        
        // 1. Perform full graceful disconnect
        await disconnect()
        
        // 2. Give a tiny moment for packets to flush then exit
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        NSApp.terminate(nil)
    }

    // MARK: - Settings Observation

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

    /// Call when the matrix layout changes to update the crossing edge.
    func updateCrossingEdgeFromMatrix() {
        let parts = settings.machineMatrixString.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let localName = localMachineName
        let remoteName = windowsMachineName
        
        guard !localName.isEmpty && !remoteName.isEmpty else { return }
        guard let localIdx = parts.firstIndex(of: localName),
              let remoteIdx = parts.firstIndex(of: remoteName) else {
            return
        }
        
        let oneRow = settings.matrixOneRow
        let isCircle = settings.matrixCircle
        
        if oneRow {
            // 1x4 layout
            if remoteIdx > localIdx {
                edgeDetector.crossingEdge = .right
            } else if remoteIdx < localIdx {
                edgeDetector.crossingEdge = .left
            }
            
            // Handle wrap-around
            if isCircle {
                if localIdx == 0 && remoteIdx == 3 {
                    edgeDetector.crossingEdge = .left
                } else if localIdx == 3 && remoteIdx == 0 {
                    edgeDetector.crossingEdge = .right
                }
            }
        } else {
            // 2x2 layout
            let localRow = localIdx / 2
            let localCol = localIdx % 2
            let remoteRow = remoteIdx / 2
            let remoteCol = remoteIdx % 2
            
            if localRow == remoteRow {
                edgeDetector.crossingEdge = remoteCol > localCol ? .right : .left
            } else if localCol == remoteCol {
                edgeDetector.crossingEdge = remoteRow > localRow ? .bottom : .top
            }
            
            // 2x2 doesn't technically wrap the same way in Mouse Without Borders, 
            // but we can just leave it as adjacent only.
        }
    }

    // MARK: - Post-Connection Startup

    private func startServicesAfterConnection(
        nm: NetworkManager,
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
        let magicHash = await nm.magicHash
        localMachineID = machineID
        windowsMachineName = connectedName
        
        updateCrossingEdgeFromMatrix()

        // Update clipboard manager with the adopted machine ID
        await cm.updateMachineID(machineID)

        // Create HeartbeatService with proper parameters
        let hb = HeartbeatService(
            machineName: settings.machineName,
            screenWidth: ScreenInfo.mainScreenSizeUInt16.width,
            screenHeight: ScreenInfo.mainScreenSizeUInt16.height,
            magicHash: magicHash,
            machineID: machineID,
            generatedKey: false // User always provides key via settings
        )
        await hb.bind(networkManager: nm)
        heartbeatService = hb

        // Start heartbeat
        await hb.start()

        // Start clipboard manager
        await cm.start()

        // Start server listener (so Windows can connect back to us)
        await sl.start()

        connectionState = .connected
        errorMessage = nil
        Logger.coordinator.info("All services started, connected to \(connectedName)")
    }

    // MARK: - Subsystem Lifecycle (ReopenSockets Pattern)

    /// Stops all subsystems (HeartbeatService, ClipboardManager, ServerListener).
    /// Called when NetworkManager enters .reconnecting or .disconnected state.
    private func stopSubsystems() {
        Logger.coordinator.info("Stopping subsystems (ReopenSockets)")
        let hb = heartbeatService
        let cm = clipboardManager
        let sl = serverListener

        Task {
            await hb?.stop()
            await cm?.stop()
            await sl?.stop()
        }
    }

    /// Restarts all subsystems after NetworkManager has reconnected.
    /// Only called for subsequent connections (not the initial one).
    /// Recreates HeartbeatService with fresh handshake params from the new connection.
    private func restartSubsystems(nm: NetworkManager) async {
        // Only restart if we have valid connection info from the new handshake
        let machineID = await nm.machineID
        let magicHash = await nm.magicHash
        let connectedName = await nm.connectedMachineName
        guard machineID != .none else {
            Logger.coordinator.warning("Skipping subsystem restart: machineID is 0 (handshake may not be complete)")
            return
        }

        localMachineID = machineID
        windowsMachineName = connectedName
        
        updateCrossingEdgeFromMatrix()

        // Update clipboard manager with the adopted machine ID
        await clipboardManager?.updateMachineID(machineID)

        // Recreate HeartbeatService with fresh params from the new connection
        let hb = HeartbeatService(
            machineName: settings.machineName,
            screenWidth: ScreenInfo.mainScreenSizeUInt16.width,
            screenHeight: ScreenInfo.mainScreenSizeUInt16.height,
            magicHash: magicHash,
            machineID: machineID,
            generatedKey: false
        )
        await hb.bind(networkManager: nm)
        heartbeatService = hb
        await hb.start()

        // Restart clipboard manager (it will reconnect internally)
        await clipboardManager?.start()

        // Restart server listener
        await serverListener?.start()

        errorMessage = nil
        Logger.coordinator.info("All services restarted after reconnection to \(connectedName)")
    }

    // MARK: - State Observation

    private func startObservingState(nm: NetworkManager) {
        statePollTask?.cancel()
        statePollTask = Task { [weak self] in
            for await state in await nm.stateStream {
                guard !Task.isCancelled else { break }
                let name = await nm.connectedMachineName
                let reason = await nm.failureReason

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.connectionState = state
                    if !name.isEmpty {
                        self.windowsMachineName = name
                    }
                    // Safety: release input capture if connection lost during crossing
                    if self.isCrossingActive && (state == .reconnecting || state == .disconnected) {
                        Logger.coordinator.warning("Connection lost during edge crossing, releasing input capture")
                        self.isCrossingActive = false
                        self.inputCapture.crossingActive = false
                        self.edgeDetector.reset()
                        self.inputInjection.reset()
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

                    // ReopenSockets pattern: stop all subsystems on disconnect/reconnecting
                    if state == .reconnecting || state == .disconnected {
                        self.stopSubsystems()
                    }

                    // Restart subsystems when connection is restored (reconnection only)
                    if state == .connected && !self.isInitialConnection {
                        Task {
                            await self.restartSubsystems(nm: nm)
                        }
                    }

                    // After the first .connected is emitted by the state observer,
                    // mark initial connection as complete so future .connected events
                    // trigger the reconnection path.
                    if state == .connected && self.isInitialConnection {
                        self.isInitialConnection = false
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

        // Send NextMachine packet so Windows knows to hand off control
        sendNextMachine(
            targetMachineID: MWBConstants.broadcastDestination,
            x: info.virtualPosition.x,
            y: info.virtualPosition.y
        )
    }

    /// Windows detected cursor reaching its edge toward the Mac — accept control.
    private func handleNextMachine(machineID: MachineID, x: Int32, y: Int32) {
        guard connectionState == .connected else { return }
        guard !isCrossingActive else { return }

        Logger.coordinator.info("Received NextMachine from machine \(machineID) at (\(x), \(y))")
        isCrossingActive = true
        inputCapture.crossingActive = true
        inputInjection.reset()

        // Warp cursor to the requested position (virtual coords -> screen coords)
        let screenPoint = virtualToScreen(x: x, y: y)
        CGWarpMouseCursorPosition(screenPoint)
    }

    // MARK: - Remote Input Handling

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

    // MARK: - Sleep / Wake

    func handleSleep() async {
        Logger.coordinator.info("OS Sleep detected, tearing down sockets")
        await disconnect()
    }

    func handleWake() {
        Logger.network.info("OS Wake detected, scheduling reconnect")
        connect()
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

    // MARK: - NextMachine

    private func sendNextMachine(targetMachineID: MachineID, x: Int32, y: Int32) {
        guard let nm = networkManager else { return }

        var packet = MWBPacket()
        packet.type = PackageType.nextMachine.rawValue
        packet.src = localMachineID
        packet.des = targetMachineID

        var mouseData = MouseData()
        mouseData.x = x
        mouseData.y = y
        mouseData.wheelDelta = Int32(bitPattern: localMachineID.rawValue)
        mouseData.write(to: &packet)

        Task {
            await nm.sendPacket(packet)
        }
    }

    // MARK: - Matrix Broadcasting

    func broadcastMatrix(slots: [String], oneRow: Bool, circle: Bool) async {
        guard let nm = networkManager else { return }

        // Compile flags: SwapFlag (2) = circle, TwoRowFlag (4) = !oneRow
        var flags: UInt8 = PackageType.matrix.rawValue
        if circle { flags |= 2 }
        if !oneRow { flags |= 4 }

        for (index, name) in slots.enumerated() {
            var packet = MWBPacket()
            packet.type = flags
            packet.src = MachineID(rawValue: UInt32(index + 1)) // Src is 1 to 4
            packet.des = MWBConstants.broadcastDestination

            let nameData = HandshakeHandler.encodeMachineName(name)
            var fullData = packet.data
            fullData.replaceSubrange(16..<48, with: nameData)
            packet.data = fullData

            await nm.sendPacket(packet)
        }
    }

    /// Convert MWB virtual desktop coordinates (0-65535) to macOS screen coordinates.
    private func virtualToScreen(x: Int32, y: Int32) -> CGPoint {
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scaleX = CGFloat(x) / CGFloat(MWBConstants.virtualDesktopMax)
        let scaleY = CGFloat(y) / CGFloat(MWBConstants.virtualDesktopMax)
        // macOS has bottom-left origin, virtual coords have top-left origin
        return CGPoint(
            x: screen.minX + scaleX * screen.width,
            y: screen.minY + (1.0 - scaleY) * screen.height
        )
    }
}
