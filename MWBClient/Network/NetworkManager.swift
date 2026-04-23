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

    // MARK: Public State

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            Logger.network.info("Connection state: \(String(describing: oldValue)) -> \(String(describing: self.state))")
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

    /// Sets all three callbacks in a single actor-isolated call.
    func setCallbacks(
        onMouse: MouseCallback?,
        onKeyboard: KeyboardCallback?,
        onClipboard: ClipboardCallback?
    ) {
        self.onMouse = onMouse
        self.onKeyboard = onKeyboard
        self.onClipboard = onClipboard
    }

    // MARK: Init

    init(
        host: String,
        port: UInt16 = MWBConstants.inputPort,
        securityKey: String,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080)
    ) {
        self.host = host
        self.port = port
        self.securityKey = securityKey
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
        Logger.network.info("Connecting to \(self.host):\(self.port)")
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
        Logger.network.info("Disconnecting")
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

    // MARK: Send

    func sendPacket(_ packet: MWBPacket) {
        guard let conn = connection, state == .connected else { return }

        let data = packet.transmittedData
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
            try await waitForConnection(conn)
        } catch let error as NWError {
            classifyAndLogConnectionError(error)
            scheduleReconnect(reason: classifyNWError(error))
            return
        } catch is NetworkError {
            Logger.network.info("Connection cancelled during wait")
            updateState(.disconnected)
            return
        } catch {
            Logger.network.error("Connection wait failed: \(error.localizedDescription)")
            scheduleReconnect(reason: .unknown(error.localizedDescription))
            return
        }

        // Phase 1: Noise exchange
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

        // Phase 3: Send identity
        do {
            try await sendIdentity(conn)
        } catch {
            Logger.network.error("Send identity failed: \(error.localizedDescription)")
            scheduleReconnect(reason: .unknown(error.localizedDescription))
            return
        }

        // Phase 4: Connected - enter receive pump
        failureReason = .none
        lastHeartbeatReceived = .now
        updateState(.connected)
        Logger.network.info("Connected successfully")
        startHeartbeatMonitor()

        if handshakeHandler.adoptedMachineID != 0 {
            machineID = handshakeHandler.adoptedMachineID
        }

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
        let encryptedNoise = crypto.encrypt(padToBlock(randomNoise))
        try await conn.send(content: encryptedNoise)

        // Receive 16 bytes of noise back
        let receivedNoise = try await conn.receive(minimumIncompleteLength: MWBConstants.noiseSize, maximumLength: MWBConstants.noiseSize)
        guard let noiseData = receivedNoise, noiseData.count == MWBConstants.noiseSize else {
            throw NetworkError.invalidNoise
        }
        _ = crypto.decrypt(padToBlock(noiseData))
    }

    // MARK: Handshake

    private func performHandshake(_ conn: NWConnection) async throws {
        // Receive and respond to 10 challenges from the server
        for i in 0..<MWBConstants.handshakeIterationCount {
            Logger.network.debug("Handshake iteration \(i): waiting for challenge")

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
            guard var ackPacket = handshakeHandler.receiveChallenge(challengePacket, localMachineName: localMachineName) else {
                throw NetworkError.handshakeFailed("handshake handler rejected challenge")
            }
            ackPacket.setMagic(magicHash)
            _ = ackPacket.computeChecksum()

            // Encrypt and send ACK
            let ackEncrypted = crypto.encrypt(padToBlock(ackPacket.transmittedData))
            Logger.network.debug("ACK \(i): type=\(ackPacket.type) m0=\(ackPacket.rawBytes[2]) m1=\(ackPacket.rawBytes[3]) cksum=\(ackPacket.rawBytes[1]) M1=\(ackPacket.dataUInt32(at: 0))")
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

        let encrypted = crypto.encrypt(padToBlock(identityPacket.transmittedData))
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
                    Logger.network.info("Receive pump: connection closed (no data)")
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
                Logger.network.debug("Receive pump: got packet type=\(packet.type) src=\(packet.src) des=\(packet.des)")

            } catch {
                Logger.network.error("Receive pump error: \(error.localizedDescription)")
                break
            }
        }

        // If we exit the pump while still "connected", schedule reconnect
        if state == .connected {
            Logger.network.info("Receive pump exited while connected, scheduling reconnect")
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
                Logger.network.debug("Dedup: dropping duplicate packet id=\(packet.id)")
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
            Logger.network.info("Received Heartbeat_ex from remote, sending Heartbeat_ex_l2")
            var l2 = MWBPacket()
            l2.type = PackageType.heartbeatExL2.rawValue
            l2.id = packet.id
            l2.src = machineID
            l2.des = packet.src
            l2.data = packet.data
            l2.setMagic(magicHash)
            _ = l2.computeChecksum()
            sendPacket(l2)

        case .clipboard, .clipboardText, .clipboardImage, .clipboardDataEnd,
             .clipboardAsk, .clipboardPush, .clipboardDragDrop, .clipboardDragDropEnd:
            onClipboard?(packet)

        case .heartbeat:
            // Echo heartbeat if needed (no-op for now, HeartbeatService handles outgoing)
            break

        case .heartbeatExL2:
            // Remote acknowledged our key generation - send confirmation with Heartbeat_ex_l3
            Logger.network.info("Received Heartbeat_ex_l2 from remote, sending Heartbeat_ex_l3")
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
            Logger.network.info("Key agreement complete with remote machine")

        case .byeBye:
            Logger.network.info("Received ByeBye packet from remote, disconnecting")
            updateState(.disconnected)

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
        guard var ack = handshakeHandler.receiveChallenge(packet, localMachineName: localMachineName) else {
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
        Logger.network.info("Disconnected due to error: \(String(describing: reason)), manual reconnect required")
    }

    private func scheduleReconnect(reason: ConnectionFailureReason = .unknown("Unknown")) {
        guard !intentionalDisconnect else {
            Logger.network.info("Skipping reconnect: intentional disconnect")
            updateState(.disconnected)
            return
        }
        updateState(.reconnecting)
        failureReason = reason
        crypto.reset()
        handshakeHandler.reset()
        stopHeartbeatMonitor()
        Logger.network.info("Scheduling reconnect in \(MWBConstants.reconnectDelay)s, reason: \(String(describing: reason))")

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
