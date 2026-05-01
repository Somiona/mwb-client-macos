import AppKit
import Foundation
import Network
import os.log
import Security

// MARK: - ServerListener

actor ServerListener {

    // MARK: Public State

    private(set) var isListening = false
    private(set) var activeConnectionCount = 0
    private(set) var remoteMachineID: UInt32 = 0

    // MARK: Configuration

    private let port: UInt16
    private let securityKey: String
    private let localMachineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16

    private let localMachineID: UInt32

    // MARK: Listener

    private var listener: NWListener?
    private var connectionTasks: Set<Task<Void, Never>> = []
    private var dedup = PackageDeduplicator()
    private var nextPacketID: UInt32 = UInt32.random(in: 1..<0x7FFFFFFF)

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
        machineID: UInt32,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080)
    ) {
        self.port = port
        self.securityKey = securityKey
        self.localMachineID = machineID
        self.localMachineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    // MARK: Start / Stop

    func start() async {
        guard !isListening else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Logger.network.error("ServerListener: invalid port \(self.port)")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            Logger.network.error("ServerListener: failed to create listener: \(error.localizedDescription)")
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
        Logger.network.info("ServerListener started on port \(self.port)")
    }

    func stop() {
        Logger.network.info("ServerListener stopping")
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
            Logger.network.info("ServerListener ready and listening")
        case .failed(let error):
            isListening = false
            Logger.network.error("ServerListener failed: \(error.localizedDescription)")
        case .cancelled:
            isListening = false
            Logger.network.info("ServerListener cancelled")
        default:
            break
        }
    }

    // MARK: New Connection

    private func handleNewConnection(_ connection: NWConnection) {
        let remoteEndpoint = connection.endpoint
        Logger.network.info("ServerListener: new connection from \(String(describing: remoteEndpoint))")
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
            Logger.network.info("ServerListener: connection closed")
            Task { [weak self] in
                await self?.connectionDidClose()
            }
        }

        // Each connection gets its own crypto instance (separate cipher state)
        let crypto = MWBCrypto(securityKey: securityKey)
        let magicHash = crypto.get24BitHash()
        var handshakeHandler = HandshakeHandler()

        // Phase 1: Noise exchange (send first, then receive — same order as outbound)
        do {
            try await exchangeNoiseOutbound(connection, crypto: crypto)
        } catch {
            Logger.network.error("ServerListener: outbound noise exchange failed: \(error.localizedDescription)")
            return
        }

        // Phase 2: Send 10 handshake challenges (matching PowerToys MainTCPRoutine)
        handshakeHandler.start()
        do {
            try await sendHandshakeChallenges(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
        } catch {
            Logger.network.error("ServerListener: send challenges failed: \(error.localizedDescription)")
            return
        }

        // Phase 3: Receive pump (handles incoming HandshakeAck verification and all other packets)
        Logger.network.info("ServerListener: entering receive pump")
        await receivePump(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
    }

    private func connectionDidClose() {
        activeConnectionCount = max(0, activeConnectionCount - 1)
        connectionTasks = connectionTasks.filter { !$0.isCancelled }
    }

    // MARK: Noise Exchange (Outbound — same order as NetworkManager)

    private func exchangeNoiseOutbound(_ conn: NWConnection, crypto: MWBCrypto) async throws {
        // Send 16 bytes of random encrypted data
        var randomNoise = Data(count: MWBConstants.noiseSize)
        randomNoise.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, MWBConstants.noiseSize, ptr.baseAddress!)
        }
        let encryptedNoise = crypto.encrypt(padToBlock(randomNoise))
        try await conn.send(content: encryptedNoise)

        // Receive 16 bytes of noise
        let receivedNoise = try await conn.receive(
            minimumIncompleteLength: MWBConstants.noiseSize,
            maximumLength: MWBConstants.noiseSize
        )
        guard let noiseData = receivedNoise, noiseData.count == MWBConstants.noiseSize else {
            throw NetworkError.invalidNoise
        }
        _ = crypto.decrypt(padToBlock(noiseData))
    }

    // MARK: Send Handshake Challenges

    private func sendHandshakeChallenges(
        _ conn: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        handler: inout HandshakeHandler
    ) async throws {
        for _ in 0..<MWBConstants.handshakeIterationCount {
            // Match PowerToys MainTCPRoutine: initialize entire 64-byte buffer with random data
            var randomData = Data(count: MWBConstants.bigPacketSize)
            randomData.withUnsafeMutableBytes { ptr in
                _ = SecRandomCopyBytes(kSecRandomDefault, MWBConstants.bigPacketSize, ptr.baseAddress!)
            }
            
            var challenge = MWBPacket(rawData: randomData)
            challenge.type = PackageType.handshake.rawValue
            challenge.id = nextPacketID
            nextPacketID &+= 1

            // src/des remain random unless adopted
            if localMachineID != 0 {
                challenge.src = localMachineID
            }

            let nameData = HandshakeHandler.encodeMachineName(localMachineName)
            var fullData = challenge.data
            fullData.replaceSubrange(16..<48, with: nameData)
            challenge.data = fullData

            challenge.setMagic(magicHash)
            _ = challenge.computeChecksum()

            let encrypted = crypto.encrypt(padToBlock(challenge.transmittedData))
            try await conn.send(content: encrypted)
        }
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
                    Logger.network.info("ServerListener receive pump: connection closed")
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
                        Logger.network.warning("ServerListener receive pump: incomplete big packet")
                        break
                    }

                    let secondDecrypted = crypto.decrypt(padToBlock(secondData))
                    fullData = firstDecrypted + secondDecrypted
                } else {
                    fullData = firstDecrypted
                }

                let packet = MWBPacket(rawData: fullData)

                guard packet.validateChecksum() else {
                    Logger.network.warning("ServerListener: invalid checksum, skipping packet")
                    continue
                }
                guard packet.validateMagic(magicHash) else {
                    Logger.network.warning("ServerListener: invalid magic, skipping packet")
                    continue
                }

                // Handle re-handshake and heartbeat echo inline; dispatch everything else
                if handleSpecialPacket(packet, connection: conn, crypto: crypto, magicHash: magicHash, handler: &handler) {
                    continue
                }

                dispatchPacket(packet)

            } catch {
                Logger.network.error("ServerListener receive pump error: \(error.localizedDescription)")
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

        case .handshakeAck:
            // Received response to our challenge: mark as trusted and store remote ID
            self.remoteMachineID = packet.src
            Logger.network.info("ServerListener: received handshakeAck from machine \(packet.src), connection trusted")
            return true

        case .heartbeat, .heartbeatEx, .heartbeatExL2, .heartbeatExL3:
            // Key agreement protocol: respond with the appropriate next level
            respondToHeartbeat(packet, connection: connection, crypto: crypto, magicHash: magicHash, machineID: handler.adoptedMachineID)
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
        guard var ack = handler.receiveChallenge(packet, localMachineName: localMachineName) else { return }
        ack.setMagic(magicHash)
        _ = ack.computeChecksum()

        let encrypted = crypto.encrypt(padToBlock(ack.transmittedData))
        connection.send(content: encrypted, completion: .contentProcessed({ _ in }))
    }

    // MARK: Heartbeat Response

    /// Respond to heartbeat types according to the key agreement protocol:
    /// - heartbeat (20): echo as heartbeatExL2 (52) for compatibility
    /// - heartbeatEx (51): respond with heartbeatExL2 (52)
    /// - heartbeatExL2 (52): respond with heartbeatExL3 (53)
    /// - heartbeatExL3 (53): key agreement complete, no response needed
    private func respondToHeartbeat(
        _ packet: MWBPacket,
        connection: NWConnection,
        crypto: MWBCrypto,
        magicHash: UInt32,
        machineID: UInt32
    ) {
        guard let type = packet.packageType else { return }

        let responseType: PackageType
        switch type {
        case .heartbeat, .heartbeatEx:
            responseType = .heartbeatExL2
            Logger.network.info("ServerListener: received heartbeat type \(type.rawValue), sending heartbeatExL2")
        case .heartbeatExL2:
            responseType = .heartbeatExL3
            Logger.network.info("ServerListener: received heartbeatExL2, sending heartbeatExL3")
        case .heartbeatExL3:
            Logger.network.info("ServerListener: received heartbeatExL3, key agreement complete")
            return
        default:
            return
        }

        var response = MWBPacket()
        response.type = responseType.rawValue
        response.id = packet.id
        response.src = machineID
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

        // Skip dedup for certain packet types (per PowerToys Receiver.cs)
        let exemptFromDedup: Set<PackageType> = [.handshake, .handshakeAck, .clipboardText, .clipboardImage]
        if !exemptFromDedup.contains(type) {
            if dedup.isDuplicate(packet.id) {
                Logger.network.debug("ServerListener dedup: dropping duplicate packet id=\(packet.id)")
                return
            }
        }

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

        case .byeBye:
            Logger.network.info("Received ByeBye packet, disconnecting")
            // ServerListener doesn't maintain state, just log it

        case .hi:
            Logger.network.info("Received Hi packet")

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
