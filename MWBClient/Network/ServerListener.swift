import AppKit
import Foundation
import Network
import Security

// MARK: - ServerListener

actor ServerListener {

    // MARK: Public State

    private(set) var isListening = false
    private(set) var activeConnectionCount = 0

    // MARK: Configuration

    private let port: UInt16
    private let securityKey: String
    private let localMachineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16

    // MARK: Listener

    private var listener: NWListener?
    private var connectionTasks: Set<Task<Void, Never>> = []

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
        port: UInt16 = MWBConstants.inputPort,
        securityKey: String,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080)
    ) {
        self.port = port
        self.securityKey = securityKey
        self.localMachineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    // MARK: Start / Stop

    func start() async {
        guard !isListening else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            return
        }

        guard let listener else { return }

        listener.stateUpdateHandler = { [weak self] newState in
            Task { [weak self] in
                await self?.handleListenerState(newState)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleNewConnection(connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        isListening = true
    }

    func stop() {
        for task in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()

        listener?.cancel()
        listener = nil
        isListening = false
        activeConnectionCount = 0
    }

    // MARK: Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
        case .failed, .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: New Connection

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleConnection(connection)
        }
        connectionTasks.insert(task)
        activeConnectionCount += 1
    }

    // MARK: Per-Connection Lifecycle

    private func handleConnection(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            Task { [weak self] in
                await self?.connectionDidClose()
            }
        }

        // Each connection gets its own crypto instance (separate cipher state)
        let crypto = MWBCrypto(securityKey: securityKey)
        let magicHash = crypto.get24BitHash()
        var handshakeHandler = HandshakeHandler()

        // Phase 1: Noise exchange (inbound: receive first, then send)
        do {
            try await exchangeNoiseInbound(connection, crypto: crypto)
        } catch {
            return
        }

        // Phase 2: Handshake (receive type 126 challenges, respond with type 127)
        handshakeHandler.start()
        do {
            try await performHandshakeInbound(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
        } catch {
            return
        }

        // Phase 3: Send identity (type 51)
        do {
            try await sendIdentityInbound(connection, crypto: crypto, magicHash: magicHash, handler: handshakeHandler)
        } catch {
            return
        }

        // Phase 4: Receive pump
        await receivePump(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
    }

    private func connectionDidClose() {
        activeConnectionCount = max(0, activeConnectionCount - 1)
        connectionTasks = connectionTasks.filter { !$0.isCancelled }
    }

    // MARK: Noise Exchange (Inbound)

    /// Inbound connection: receive noise first, then send noise.
    /// This is the reverse order from outbound (NetworkManager).
    private func exchangeNoiseInbound(_ conn: NWConnection, crypto: MWBCrypto) async throws {
        // Receive 16 bytes of noise from the remote
        let receivedNoise = try await conn.receive(
            minimumIncompleteLength: MWBConstants.noiseSize,
            maximumLength: MWBConstants.noiseSize
        )
        guard let noiseData = receivedNoise, noiseData.count == MWBConstants.noiseSize else {
            throw NetworkError.invalidNoise
        }
        _ = crypto.decrypt(padToBlock(noiseData))

        // Send 16 bytes of random encrypted data back
        var randomNoise = Data(count: MWBConstants.noiseSize)
        randomNoise.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, MWBConstants.noiseSize, ptr.baseAddress!)
        }
        let encryptedNoise = crypto.encrypt(padToBlock(randomNoise))
        try await conn.send(content: encryptedNoise)
    }

    // MARK: Handshake (Inbound)

    /// Receive 10 type 126 challenges, respond with type 127 ACKs.
    private func performHandshakeInbound(
        _ conn: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: inout HandshakeHandler
    ) async throws {
        for _ in 0..<MWBConstants.handshakeIterationCount {
            let raw = try await conn.receive(
                minimumIncompleteLength: MWBConstants.smallPacketSize,
                maximumLength: MWBConstants.smallPacketSize
            )
            guard let challengeEncrypted = raw, challengeEncrypted.count == MWBConstants.smallPacketSize else {
                throw NetworkError.handshakeFailed("incomplete challenge packet")
            }

            let challengeDecrypted = crypto.decrypt(padToBlock(challengeEncrypted))
            let challengePacket = MWBPacket(rawData: challengeDecrypted)

            guard challengePacket.packageType == .handshake else {
                throw NetworkError.handshakeFailed("expected type 126, got \(challengePacket.type)")
            }

            guard var ackPacket = handler.receiveChallenge(challengePacket) else {
                throw NetworkError.handshakeFailed("handshake handler rejected challenge")
            }
            ackPacket.setMagic(magicHash)
            _ = ackPacket.computeChecksum()

            let ackEncrypted = crypto.encrypt(padToBlock(ackPacket.transmittedData))
            try await conn.send(content: ackEncrypted)
        }

        guard handler.completeIfReady() else {
            throw NetworkError.handshakeFailed("handshake not complete after \(MWBConstants.handshakeIterationCount) iterations")
        }
    }

    // MARK: Identity (Inbound)

    /// Send identity packet (type 51 / heartbeatEx) to the connecting machine.
    private func sendIdentityInbound(
        _ conn: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: HandshakeHandler
    ) async throws {
        var identityPacket = HandshakeHandler.makeIdentityPacket(
            machineName: localMachineName,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            machineID: handler.adoptedMachineID
        )
        identityPacket.setMagic(magicHash)
        _ = identityPacket.computeChecksum()

        let encrypted = crypto.encrypt(padToBlock(identityPacket.transmittedData))
        try await conn.send(content: encrypted)
    }

    // MARK: Receive Pump

    /// Main loop: read packets, decrypt, dispatch. Handles re-handshake and heartbeat echo.
    private func receivePump(
        _ conn: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: inout HandshakeHandler
    ) async {
        while !Task.isCancelled {
            do {
                // Read first 32 bytes
                let firstChunk = try await conn.receive(
                    minimumIncompleteLength: MWBConstants.smallPacketSize,
                    maximumLength: MWBConstants.smallPacketSize
                )

                guard let firstData = firstChunk, firstData.count == MWBConstants.smallPacketSize else {
                    break
                }

                let firstDecrypted = crypto.decrypt(padToBlock(firstData))

                let packetType = firstDecrypted[0]
                let isBig = PackageType(rawValue: packetType)?.isBig ?? ((packetType & 0x80) != 0)

                var fullData: Data
                if isBig {
                    let secondChunk = try await conn.receive(
                        minimumIncompleteLength: MWBConstants.smallPacketSize,
                        maximumLength: MWBConstants.smallPacketSize
                    )

                    guard let secondData = secondChunk, secondData.count == MWBConstants.smallPacketSize else {
                        break
                    }

                    let secondDecrypted = crypto.decrypt(padToBlock(secondData))
                    fullData = firstDecrypted + secondDecrypted
                } else {
                    fullData = firstDecrypted
                }

                let packet = MWBPacket(rawData: fullData)

                guard packet.validateChecksum() else { continue }
                guard packet.validateMagic(magicHash) else { continue }

                // Handle re-handshake and heartbeat echo inline; dispatch everything else
                if await handleSpecialPacket(packet, connection: conn, crypto: crypto, magicHash: magicHash, handler: &handler) {
                    continue
                }

                await dispatchPacket(packet)

            } catch {
                break
            }
        }
    }

    // MARK: Special Packet Handling

    /// Returns true if the packet was handled as a special case (re-handshake or heartbeat echo).
    private func handleSpecialPacket(
        _ packet: MWBPacket,
        connection: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: inout HandshakeHandler
    ) -> Bool {
        guard let type = packet.packageType else { return false }

        switch type {
        case .handshake:
            // Re-handshake during active session: respond with type 127
            handleRehandshake(packet, connection: connection, crypto: crypto, magicHash: magicHash, handler: &handler)
            return true

        case .heartbeat, .heartbeatEx, .heartbeatExL2, .heartbeatExL3:
            // Echo heartbeat back
            echoHeartbeat(packet, connection: connection, crypto: crypto, magicHash: magicHash)
            return true

        default:
            return false
        }
    }

    // MARK: Re-handshake

    /// Respond to a type 126 (handshake) packet during an active session.
    private func handleRehandshake(
        _ packet: MWBPacket,
        connection: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: inout HandshakeHandler
    ) {
        guard var ack = handler.receiveChallenge(packet) else { return }
        ack.setMagic(magicHash)
        _ = ack.computeChecksum()

        let encrypted = crypto.encrypt(padToBlock(ack.transmittedData))
        connection.send(content: encrypted, completion: .contentProcessed({ _ in }))
    }

    // MARK: Heartbeat Echo

    /// Respond to heartbeat types 51/52/53 by echoing a type 52 (heartbeatExL2) back.
    private func echoHeartbeat(
        _ packet: MWBPacket,
        connection: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32
    ) {
        var response = MWBPacket()
        response.type = PackageType.heartbeatExL2.rawValue
        response.id = packet.id
        response.src = packet.des
        response.des = packet.src
        response.data = packet.data
        response.setMagic(magicHash)
        _ = response.computeChecksum()

        let encrypted = crypto.encrypt(padToBlock(response.transmittedData))
        connection.send(content: encrypted, completion: .contentProcessed({ _ in }))
    }

    // MARK: Packet Dispatch

    /// Dispatch regular (non-special) packets to registered callbacks.
    private func dispatchPacket(_ packet: MWBPacket) {
        guard let type = packet.packageType else { return }

        switch type {
        case .mouse:
            let mouseData = MouseData(from: packet)
            onMouse?(mouseData)

        case .keyboard:
            let keyData = KeyboardData(from: packet)
            onKeyboard?(keyData)

        case .clipboard, .clipboardText, .clipboardImage, .clipboardDataEnd,
             .clipboardAsk, .clipboardPush, .clipboardDragDrop, .clipboardDragDropEnd:
            onClipboard?(packet)

        default:
            break
        }
    }

    // MARK: Helpers

    /// Pad data to AES block size (16 bytes) with zero bytes.
    private func padToBlock(_ data: Data) -> Data {
        let remainder = data.count % MWBConstants.ivLength
        if remainder == 0 { return data }
        return data + Data(count: MWBConstants.ivLength - remainder)
    }
}
