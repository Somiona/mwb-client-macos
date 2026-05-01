import AppKit
import Foundation
import Network
import os.log
import Security

// MARK: - Connection State

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case reconnecting
}

// MARK: - Connection Error Type

/// Categorizes why a connection attempt failed, used for UI error messages.
enum ConnectionFailureReason: Sendable, Equatable {
    case none
    case connectionRefused
    case timeout
    case handshakeFailed
    case hostUnreachable
    case cancelled
    case unknown(String)
}

// MARK: - NetworkManager

actor NetworkManager {

    /// Toggle to enable verbose logging of every connection step.
    /// Set to true for debugging, false for release.
    static let debugConnectionSteps = true

    // MARK: Public State

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if Self.debugConnectionSteps {
                Logger.network.info("Connection state: \(String(describing: oldValue)) -> \(String(describing: self.state))")
            }
        }
    }
    private(set) var machineID: UInt32 = 0
    private(set) var connectedMachineName: String = ""
    private(set) var magicHash: UInt32 = 0

    /// The reason the last connection attempt failed. Reset on successful connection.
    private(set) var failureReason: ConnectionFailureReason = .none

    // MARK: Configuration

    private let host: String
    private let port: UInt16
    private let securityKey: String
    private let localMachineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16

    // MARK: Crypto & Protocol State

    private var crypto: MWBCrypto
    private var handshakeHandler = HandshakeHandler()

    // MARK: Connection

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatMonitorTask: Task<Void, Never>?
    private var intentionalDisconnect = false
    private var dedup = PackageDeduplicator()
    private var nextPacketID: UInt32 = UInt32.random(in: 1..<0x7FFFFFFF)

    // MARK: Heartbeat Timeout Tracking

    private var lastHeartbeatReceived: ContinuousClock.Instant = .now

    // MARK: State Stream

    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

    /// Stream of connection state changes. Consumers can iterate with `for await`.
    private let _stateStream = AsyncStream<ConnectionState>.makeStream()

    var stateStream: AsyncStream<ConnectionState> {
        _stateStream.stream
    }

    // MARK: Callbacks

    var onMouse: MouseCallback?
    var onKeyboard: KeyboardCallback?
    var onClipboard: ClipboardCallback?
    var onNextMachine: (@Sendable (UInt32, Int32, Int32) -> Void)?

    /// Sets all four callbacks in a single actor-isolated call.
    func setCallbacks(
        onMouse: MouseCallback?,
        onKeyboard: KeyboardCallback?,
        onClipboard: ClipboardCallback?,
        onNextMachine: (@Sendable (UInt32, Int32, Int32) -> Void)? = nil
    ) {
        self.onMouse = onMouse
        self.onKeyboard = onKeyboard
        self.onClipboard = onClipboard
        self.onNextMachine = onNextMachine
    }

    // MARK: Init

    init(
        host: String,
        port: UInt16 = MWBConstants.inputPort,
        securityKey: String,
        machineID: UInt32,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080)
    ) {
        self.host = host
        self.port = port
        self.securityKey = securityKey
        self.machineID = machineID
        self.localMachineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.crypto = MWBCrypto(securityKey: securityKey)
        self.magicHash = crypto.get24BitHash()
        self.stateContinuation = _stateStream.continuation
    }

    /// Updates the connection state and yields the new state to all stream consumers.
    private func updateState(_ newState: ConnectionState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    // Note: deinit cannot call actor-isolated methods.
    // Callers must call disconnect() before releasing the actor.

    // MARK: Connect / Disconnect

    func connect() {
        guard state == .disconnected || state == .reconnecting else { return }

        intentionalDisconnect = false
        if Self.debugConnectionSteps {
            Logger.network.info("Connecting to \(self.host):\(self.port)")
        }
        failureReason = .none
        updateState(.connecting)

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }

        connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)

        guard let conn = connection else { return }

        conn.start(queue: .global(qos: .userInitiated))

        startReceiveLoop()
    }

    func disconnect() {
        if Self.debugConnectionSteps {
            Logger.network.info("Disconnecting")
        }
        intentionalDisconnect = true
        failureReason = .none
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        dedup.reset()
        updateState(.disconnected)
    }

    /// Sends a ByeBye packet (type 4) to the remote machine to gracefully announce disconnection.
    func sendByeBye() async {
        guard state == .connected else { return }
        
        var packet = MWBPacket()
        packet.type = PackageType.byeBye.rawValue
        packet.src = machineID
        packet.des = MWBConstants.broadcastDestination
        
        let nameData = HandshakeHandler.encodeMachineName(localMachineName)
        var fullData = packet.data
        fullData.replaceSubrange(16..<48, with: nameData)
        packet.data = fullData
        
        // We use a manual send here because sendPacket() only works if state is .connected,
        // and we want to ensure it's sent even if we are about to transition state.
        if let conn = connection {
            packet.id = nextPacketID
            nextPacketID &+= 1
            packet.setMagic(magicHash)
            _ = packet.computeChecksum()
            
            let data = packet.transmittedData
            let encrypted = crypto.encrypt(padToBlock(data))
            
            // Send synchronously-ish (await completion) to ensure it's on the wire before process exits
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                conn.send(content: encrypted, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    // MARK: Send

    func sendPacket(_ packet: MWBPacket) {
        guard let conn = connection, state == .connected else { return }

        var mutablePacket = packet
        mutablePacket.id = nextPacketID
        nextPacketID &+= 1
        
        mutablePacket.setMagic(magicHash)
        _ = mutablePacket.computeChecksum()

        let data = mutablePacket.transmittedData
        let encrypted = crypto.encrypt(padToBlock(data))

        conn.send(content: encrypted, completion: .contentProcessed { error in
            if let error {
                Logger.network.error("Send failed: \(error.localizedDescription)")
            }
        })
    }

    // MARK: Internal - Receive Loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectionSequence()
        }
    }

    private func runConnectionSequence() async {
        guard let conn = connection else {
            Logger.network.error("No connection available")
            updateState(.disconnected)
            return
        }

        // Wait for TCP connection to establish
        do {
            Logger.network.info("Waiting for connection establish")
            try await waitForConnection(conn)
        } catch let error as NWError {
            classifyAndLogConnectionError(error)
            scheduleReconnect(reason: classifyNWError(error))
            return
        } catch is NetworkError {
            if Self.debugConnectionSteps {
                Logger.network.info("Connection cancelled during wait")
            }
            updateState(.disconnected)
            return
        } catch {
            Logger.network.error("Connection wait failed: \(error.localizedDescription)")
            scheduleReconnect(reason: .unknown(error.localizedDescription))
            return
        }

        // Phase 1: Noise exchange (matches Windows SendOrReceiveARandomDataBlockPerInitialIV)
        updateState(.connecting)
        do {
            try await exchangeNoise(conn)
        } catch {
            Logger.network.error("Noise exchange failed: \(error.localizedDescription)")
            disconnectDueToError(.handshakeFailed)
            return
        }

        // Phase 2: Handshake
        updateState(.handshaking)
        handshakeHandler.start()
        do {
            try await performHandshake(conn)
        } catch let error as NetworkError {
            Logger.network.error("Handshake failed (NetworkError): \(error)")
            disconnectDueToError(.handshakeFailed)
            return
        } catch let error as NWError {
            Logger.network.error("Handshake failed (NWError): \(error)")
            disconnectDueToError(.handshakeFailed)
            return
        } catch {
            Logger.network.error("Handshake failed (unknown): \(type(of: error)) - \(error)")
            disconnectDueToError(.handshakeFailed)
            return
        }

        // Phase 2: Send identity
        do {
            try await sendIdentity(conn)
        } catch {
            Logger.network.error("Send identity failed: \(error.localizedDescription)")
            scheduleReconnect(reason: .unknown(error.localizedDescription))
            return
        }

        // Phase 3: Connected - enter receive pump
        failureReason = .none
        lastHeartbeatReceived = .now
        updateState(.connected)
        if Self.debugConnectionSteps {
            let now = MWBCrypto.stamp()
            Logger.network.info("[\(now)] Connected successfully (ID: \(self.machineID))")
        }
        startHeartbeatMonitor()

        await receivePump(conn)
    }

    private func waitForConnection(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let flag = ResumeOnce()
            conn.stateUpdateHandler = { newState in
                guard !flag.fired else { return }
                switch newState {
                case .ready:
                    flag.fired = true
                    continuation.resume()
                case .failed(let error):
                    flag.fired = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    flag.fired = true
                    continuation.resume(throwing: NetworkError.connectionCancelled)
                default:
                    break
                }
            }
        }
    }

    // MARK: Noise Exchange

    private func exchangeNoise(_ conn: NWConnection) async throws {
        // Send 16 bytes of random encrypted data
        var randomNoise = Data(count: MWBConstants.noiseSize)
        randomNoise.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, MWBConstants.noiseSize, ptr.baseAddress!)
        }
        let now = MWBCrypto.stamp()
        Logger.crypto.debug("[\(now)] [PHASE] noise-send: \(randomNoise.count) bytes plaintext")
        let encryptedNoise = crypto.encrypt(padToBlock(randomNoise))
        let now2 = MWBCrypto.stamp()
        Logger.crypto.debug("[\(now2)] [PHASE] noise-send: \(encryptedNoise.count) bytes ciphertext on wire")
        try await conn.send(content: encryptedNoise)

        // Receive 16 bytes of noise back
        let receivedNoise = try await conn.receive(minimumIncompleteLength: MWBConstants.noiseSize, maximumLength: MWBConstants.noiseSize)
        guard let noiseData = receivedNoise, noiseData.count == MWBConstants.noiseSize else {
            throw NetworkError.invalidNoise
        }
        let now3 = MWBCrypto.stamp()
        Logger.crypto.debug("[\(now3)] [PHASE] noise-recv: \(noiseData.count) bytes ciphertext from wire")
        _ = crypto.decrypt(padToBlock(noiseData))
        let now4 = MWBCrypto.stamp()
        Logger.crypto.debug("[\(now4)] [PHASE] noise-recv: decrypted")
    }

    // MARK: Handshake

    private func performHandshake(_ conn: NWConnection) async throws {
        // Receive and respond to 10 challenges from the server
        let now = MWBCrypto.stamp(); Logger.crypto.debug("[\(now)] [PHASE] handshake-start: expecting \(MWBConstants.handshakeIterationCount) challenges")
        for i in 0..<MWBConstants.handshakeIterationCount {
            if Self.debugConnectionSteps {
                Logger.network.debug("Handshake iteration \(i): waiting for challenge")
            }

            // Read first 32 bytes (encrypted)
            let rawFirst = try await conn.receive(
                minimumIncompleteLength: MWBConstants.smallPacketSize,
                maximumLength: MWBConstants.smallPacketSize
            )
            guard let firstEncrypted = rawFirst, firstEncrypted.count == MWBConstants.smallPacketSize else {
                throw NetworkError.handshakeFailed("incomplete challenge packet")
            }

            let firstDecrypted = crypto.decrypt(firstEncrypted)

            // Check if this is a big packet — if so, read second 32 bytes
            let packetType = firstDecrypted[0]
            let isBig = PackageType(rawValue: packetType)?.isBig ?? ((packetType & 0x80) != 0)

            let fullDecrypted: Data
            if isBig {
                let rawSecond = try await conn.receive(
                    minimumIncompleteLength: MWBConstants.smallPacketSize,
                    maximumLength: MWBConstants.smallPacketSize
                )
                guard let secondEncrypted = rawSecond, secondEncrypted.count == MWBConstants.smallPacketSize else {
                    throw NetworkError.handshakeFailed("incomplete big packet second half")
                }
                let secondDecrypted = crypto.decrypt(secondEncrypted)
                fullDecrypted = firstDecrypted + secondDecrypted
            } else {
                fullDecrypted = firstDecrypted
            }

            let challengePacket = MWBPacket(rawData: fullDecrypted)

            guard challengePacket.packageType == .handshake else {
                throw NetworkError.handshakeFailed("expected type 126, got \(challengePacket.type)")
            }

            // Build ACK (bitwise NOT of challenge data)
            guard var ackPacket = handshakeHandler.receiveChallenge(challengePacket, localMachineName: localMachineName, localMachineID: machineID) else {
                throw NetworkError.handshakeFailed("handshake handler rejected challenge")
            }
            ackPacket.setMagic(magicHash)
            _ = ackPacket.computeChecksum()

            // Encrypt and send ACK
            let ackEncrypted = crypto.encrypt(padToBlock(ackPacket.transmittedData))
            if Self.debugConnectionSteps {
                Logger.network.debug("ACK \(i): type=\(ackPacket.type) m0=\(ackPacket.rawBytes[2]) m1=\(ackPacket.rawBytes[3]) cksum=\(ackPacket.rawBytes[1]) M1=\(ackPacket.dataUInt32(at: 0))")
            }
            try await conn.send(content: ackEncrypted)
        }

        guard handshakeHandler.completeIfReady() else {
            throw NetworkError.handshakeFailed("handshake not complete after \(MWBConstants.handshakeIterationCount) iterations")
        }
    }

    // MARK: Identity

    private func sendIdentity(_ conn: NWConnection) async throws {
        let id = handshakeHandler.adoptedMachineID != 0 ? handshakeHandler.adoptedMachineID : machineID
        var identityPacket = HandshakeHandler.makeIdentityPacket(
            machineName: localMachineName,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            machineID: id
        )
        identityPacket.setMagic(magicHash)
        _ = identityPacket.computeChecksum()

        let txData = identityPacket.transmittedData
        let now = MWBCrypto.stamp(); Logger.crypto.debug("[\(now)] [PHASE] identity-send: \(txData.count) bytes plaintext, isBig=\(identityPacket.isBig), type=\(identityPacket.type)")
        let encrypted = crypto.encrypt(padToBlock(txData))
        let now2 = MWBCrypto.stamp(); Logger.crypto.debug("[\(now2)] [PHASE] identity-send: \(encrypted.count) bytes ciphertext on wire")
        try await conn.send(content: encrypted)
        handshakeHandler.completeIdentity()
    }

    // MARK: Receive Pump

    private func receivePump(_ conn: NWConnection) async {
        while !Task.isCancelled {
            do {
                // Read first 32 bytes
                let firstChunk = try await conn.receive(
                    minimumIncompleteLength: MWBConstants.smallPacketSize,
                    maximumLength: MWBConstants.smallPacketSize
                )

                guard let firstData = firstChunk, firstData.count == MWBConstants.smallPacketSize else {
                    if Self.debugConnectionSteps {
                        let now = MWBCrypto.stamp()
                        Logger.network.info("[\(now)] Receive pump: connection closed (no data)")
                    }
                    break // Connection closed or error
                }

                let firstDecrypted = crypto.decrypt(padToBlock(firstData))

                // Determine if this is a "big" packet by checking the type byte
                let packetType = firstDecrypted[0]
                let isBig = PackageType(rawValue: packetType)?.isBig ?? ((packetType & 0x80) != 0)

                var fullData: Data
                if isBig {
                    // Read second 32 bytes
                    let secondChunk = try await conn.receive(
                        minimumIncompleteLength: MWBConstants.smallPacketSize,
                        maximumLength: MWBConstants.smallPacketSize
                    )

                    guard let secondData = secondChunk, secondData.count == MWBConstants.smallPacketSize else {
                        Logger.network.warning("Receive pump: incomplete big packet (partial read)")
                        break
                    }

                    let secondDecrypted = crypto.decrypt(padToBlock(secondData))
                    fullData = firstDecrypted + secondDecrypted
                } else {
                    fullData = firstDecrypted
                }

                let packet = MWBPacket(rawData: fullData)

                guard packet.validateChecksum() else {
                    Logger.network.warning("Receive pump: invalid checksum, skipping packet")
                    continue
                }
                guard packet.validateMagic(magicHash) else {
                    Logger.network.warning("Receive pump: invalid magic, skipping packet")
                    continue
                }

                dispatchPacket(packet)
                if Self.debugConnectionSteps {
                    Logger.network.debug("Receive pump: got packet type=\(packet.type) src=\(packet.src) des=\(packet.des)")
                }

            } catch {
                Logger.network.error("Receive pump error: \(error.localizedDescription)")
                break
            }
        }

        // If we exit the pump while still "connected", schedule reconnect
        if state == .connected {
            if Self.debugConnectionSteps {
                Logger.network.info("Receive pump exited while connected, scheduling reconnect")
            }
            scheduleReconnect(reason: .unknown("Connection lost"))
        }
    }

    // MARK: Packet Dispatch

    private func dispatchPacket(_ packet: MWBPacket) {
        guard let type = packet.packageType else { return }

        // Skip dedup for certain packet types (per PowerToys Receiver.cs)
        let exemptFromDedup: Set<PackageType> = [.handshake, .handshakeAck, .clipboardText, .clipboardImage]
        if !exemptFromDedup.contains(type) {
            if dedup.isDuplicate(packet.id) {
                if Self.debugConnectionSteps {
                    Logger.network.debug("Dedup: dropping duplicate packet id=\(packet.id)")
                }
                return
            }
        }

        // Track heartbeat timestamp for timeout monitoring
        let heartbeatTypes: Set<PackageType> = [.heartbeat, .heartbeatEx, .heartbeatExL2, .heartbeatExL3]
        if heartbeatTypes.contains(type) {
            lastHeartbeatReceived = .now
        }

        switch type {
        case .mouse:
            let mouseData = MouseData(from: packet)
            onMouse?(mouseData)

        case .nextMachine:
            let mouseData = MouseData(from: packet)
            let targetMachineID = UInt32(bitPattern: mouseData.wheelDelta)
            if Self.debugConnectionSteps {
                Logger.network.info("Received NextMachine: target=\(targetMachineID), pos=(\(mouseData.x),\(mouseData.y))")
            }
            onNextMachine?(targetMachineID, mouseData.x, mouseData.y)

        case .keyboard:
            let keyData = KeyboardData(from: packet)
            onKeyboard?(keyData)

        case .handshake:
            // Re-handshake during active session
            handleRehandshake(packet)

        case .heartbeatEx:
            // Remote generated a new key - acknowledge with Heartbeat_ex_l2
            let nameBytes = packet.data[16..<48]
            if let name = String(data: Data(nameBytes), encoding: .ascii) {
                connectedMachineName = name.trimmingCharacters(in: .whitespaces)
            }
            if Self.debugConnectionSteps {
                Logger.network.info("Received Heartbeat_ex from remote, sending Heartbeat_ex_l2")
            }
            var l2 = MWBPacket()
            l2.type = PackageType.heartbeatExL2.rawValue
            l2.id = packet.id
            l2.src = machineID
            l2.des = packet.src
            l2.data = packet.data
            l2.setMagic(magicHash)
            _ = l2.computeChecksum()
            sendPacket(l2)

        case .matrix:
            let nameBytes = packet.data[16..<48]
            guard let name = String(data: Data(nameBytes), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) else { break }
            let slotIndex = Int(packet.src) // 1, 2, 3, or 4
            
            Task {
                await MachinePool.shared.updateMatrixSlot(slotIndex, with: name)
                
                if slotIndex == 4 {
                    // Packet 4 is the final packet. Read flags and save.
                    let flags = packet.type
                    let matrixCircle = (flags & 2) != 0
                    let matrixOneRow = (flags & 4) == 0 // Note: flag 4 means TWO row, so OneRow is false if flag 4 is present.
                    
                    let newMatrixStr = await MachinePool.shared.serializedMatrix()
                    
                    await MainActor.run {
                        let settings = SettingsStore()
                        settings.machineMatrixString = newMatrixStr
                        settings.matrixCircle = matrixCircle
                        settings.matrixOneRow = matrixOneRow
                    }
                    if Self.debugConnectionSteps {
                        Logger.network.info("Committed new matrix from remote: \(newMatrixStr)")
                    }
                }
            }

        case .clipboard, .clipboardText, .clipboardImage, .clipboardDataEnd,
             .clipboardAsk, .clipboardPush, .clipboardDragDrop, .clipboardDragDropEnd:
            onClipboard?(packet)

        case .heartbeat:
            // Echo heartbeat if needed (no-op for now, HeartbeatService handles outgoing)
            break

        case .heartbeatExL2:
            // Remote acknowledged our key generation - send confirmation with Heartbeat_ex_l3
            if Self.debugConnectionSteps {
                Logger.network.info("Received Heartbeat_ex_l2 from remote, sending Heartbeat_ex_l3")
            }
            var l3 = MWBPacket()
            l3.type = PackageType.heartbeatExL3.rawValue
            l3.id = packet.id
            l3.src = machineID
            l3.des = packet.src
            l3.data = packet.data
            l3.setMagic(magicHash)
            _ = l3.computeChecksum()
            sendPacket(l3)

        case .heartbeatExL3:
            // Key agreement complete
            if Self.debugConnectionSteps {
                Logger.network.info("Key agreement complete with remote machine")
            }

        case .byeBye:
            if Self.debugConnectionSteps {
                Logger.network.info("Received ByeBye packet from remote, disconnecting")
            }
            updateState(.disconnected)

        case .hi:
            if Self.debugConnectionSteps {
                Logger.network.info("Received Hi packet from remote")
            }

        default:
            break
        }
    }

    // MARK: Heartbeat Timeout Monitor

    private func startHeartbeatMonitor() {
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: MWBConstants.heartbeatCheckInterval)
                } catch {
                    return // Cancelled
                }
                guard !Task.isCancelled, let self else { return }
                let timeout = await self.checkHeartbeatTimeout()
                if timeout {
                    return
                }
            }
        }
    }

    private func checkHeartbeatTimeout() -> Bool {
        let elapsed = ContinuousClock.Instant.now - lastHeartbeatReceived
        if elapsed > .seconds(MWBConstants.heartbeatTimeout) {
            Logger.network.warning("Heartbeat timeout: no heartbeat received for >\(MWBConstants.heartbeatTimeout)s, disconnecting")
            scheduleReconnect(reason: .timeout)
            return true
        }
        return false
    }

    private func stopHeartbeatMonitor() {
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
    }

    // MARK: Re-handshake

    private func handleRehandshake(_ packet: MWBPacket) {
        guard var ack = handshakeHandler.receiveChallenge(packet, localMachineName: localMachineName, localMachineID: machineID) else {
            Logger.network.warning("Re-handshake: handler rejected challenge")
            return
        }
        ack.setMagic(magicHash)
        _ = ack.computeChecksum()

        guard let conn = connection else { return }
        let encrypted = crypto.encrypt(padToBlock(ack.transmittedData))
        conn.send(content: encrypted, completion: .contentProcessed { error in
            if let error {
                Logger.network.error("Re-handshake send failed: \(error.localizedDescription)")
            }
        })
    }

    // MARK: Reconnect

    private func disconnectDueToError(_ reason: ConnectionFailureReason) {
        guard !intentionalDisconnect else { return }
        updateState(.disconnected)
        failureReason = reason
        crypto.reset()
        handshakeHandler.reset()
        connection?.cancel()
        connection = nil
        stopHeartbeatMonitor()
        if Self.debugConnectionSteps {
            Logger.network.info("Disconnected due to error: \(String(describing: reason)), manual reconnect required")
        }
    }

    private func scheduleReconnect(reason: ConnectionFailureReason = .unknown("Unknown")) {
        guard !intentionalDisconnect else {
            if Self.debugConnectionSteps {
                Logger.network.info("Skipping reconnect: intentional disconnect")
            }
            updateState(.disconnected)
            return
        }
        updateState(.reconnecting)
        failureReason = reason
        crypto.reset()
        handshakeHandler.reset()
        stopHeartbeatMonitor()
        if Self.debugConnectionSteps {
            Logger.network.info("Scheduling reconnect in \(MWBConstants.reconnectDelay)s, reason: \(String(describing: reason))")
        }

        connection?.cancel()
        connection = nil

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(MWBConstants.reconnectDelay * 1_000_000_000))
            } catch {
                return // Cancelled
            }
            guard !Task.isCancelled else { return }
            await self.connect()
        }
    }

    // MARK: Helpers

    /// Pad data to AES block size (16 bytes) with zero bytes.
    private func padToBlock(_ data: Data) -> Data {
        let remainder = data.count % MWBConstants.ivLength
        if remainder == 0 { return data }
        return data + Data(count: MWBConstants.ivLength - remainder)
    }

    // MARK: Error Classification

    /// Logs a detailed message for the given NWError.
    private func classifyAndLogConnectionError(_ error: NWError) {
        switch error {
        case .posix(.ECONNREFUSED):
            Logger.network.error("Connection refused (ECONNREFUSED) to \(self.host):\(self.port)")
        case .posix(.ETIMEDOUT):
            Logger.network.error("Connection timed out (ETIMEDOUT) to \(self.host):\(self.port)")
        case .posix(.EHOSTUNREACH):
            Logger.network.error("Host unreachable (EHOSTUNREACH): \(self.host)")
        case .posix(.ENETUNREACH):
            Logger.network.error("Network unreachable (ENETUNREACH)")
        case .posix(let code):
            Logger.network.error("Connection failed (POSIX \(code.rawValue)): \(error.localizedDescription)")
        case .tls:
            Logger.network.error("TLS error: \(error.localizedDescription)")
        case .dns:
            Logger.network.error("DNS error: \(error.localizedDescription)")
        case .wifiAware:
            Logger.network.error("WiFi Aware error: \(error.localizedDescription)")
        @unknown default:
            Logger.network.error("Unknown connection error: \(error.localizedDescription)")
        }
    }

    /// Maps an NWError to a ConnectionFailureReason for UI display.
    private func classifyNWError(_ error: NWError) -> ConnectionFailureReason {
        switch error {
        case .posix(.ECONNREFUSED):
            return .connectionRefused
        case .posix(.ETIMEDOUT):
            return .timeout
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return .hostUnreachable
        case .posix(.ECANCELED):
            return .cancelled
        case .posix:
            return .unknown(error.localizedDescription)
        case .dns:
            return .hostUnreachable
        default:
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: OS Sleep / Wake

    // handleSleep and handleWake are now managed by AppCoordinator

    // MARK: Configuration Updates

    func updateHost(_ newHost: String) {
        // Host is immutable per connection lifecycle; call disconnect + connect to change.
    }
}

// MARK: - NWConnection Async Extensions

extension NWConnection {
    func send(content: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.send(content: content, completion: .contentProcessed({ error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }))
        }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            self.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

// MARK: - Network Errors

enum NetworkError: Error, Sendable {
    case connectionCancelled
    case invalidNoise
    case handshakeFailed(String)
}
