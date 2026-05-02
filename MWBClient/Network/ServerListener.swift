import AppKit
import Darwin
import Foundation
import Network
import os.log
import Security

// MARK: - ServerListener

actor ServerListener {

    // MARK: Public State

    private(set) var isListening = false
    private(set) var activeConnectionCount = 0
    private(set) var remoteMachineID: MachineID = .none

    // MARK: Configuration

    private let port: UInt16
    private let securityKey: String
    private let localMachineID: MachineID
    private let localMachineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16
    private let settings: SettingsStore

    // MARK: Listener

    private var listener: NWListener?
    private var connectionTasks: [UInt32: Task<Void, Never>] = [:]
    private var connections: [UInt32: (NWConnection, MWBCrypto, UInt32)] = [:]
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
        machineID: MachineID,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080),
        settings: SettingsStore
    ) {
        self.port = port
        self.securityKey = securityKey
        self.localMachineID = machineID
        self.localMachineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.settings = settings
    }

    // MARK: Start / Stop

    func start() async {
        guard !isListening else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            mwbError(MWBLog.network,"ServerListener: invalid port \(self.port)")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            mwbError(MWBLog.network,"ServerListener: failed to create listener: \(error.localizedDescription)")
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
        mwbInfo(MWBLog.network,"ServerListener started on port \(self.port)")
    }

    func stop() {
        mwbInfo(MWBLog.network,"ServerListener stopping")
        let tasks = connectionTasks.values
        let conns = connections.values.map { $0.0 }
        connectionTasks.removeAll()
        connections.removeAll()

        for task in tasks {
            task.cancel()
        }
        for conn in conns {
            conn.cancel()
        }

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
            mwbInfo(MWBLog.network,"ServerListener ready and listening")
        case .failed(let error):
            isListening = false
            mwbError(MWBLog.network,"ServerListener failed: \(error.localizedDescription)")
        case .cancelled:
            isListening = false
            mwbInfo(MWBLog.network,"ServerListener cancelled")
        default:
            break
        }
    }

    // MARK: New Connection

    private func handleNewConnection(_ connection: NWConnection) {
        let remoteEndpoint = connection.endpoint
        mwbInfo(MWBLog.network,"ServerListener: new connection from \(String(describing: remoteEndpoint))")
        
        Task { [weak self] in
            guard let self else { return }
            
            if await !validateEndpoint(remoteEndpoint) {
                mwbWarning(MWBLog.network,"ServerListener: connection from \(String(describing: remoteEndpoint)) rejected by security policy")
                connection.cancel()
                return
            }
            
            connection.start(queue: .global(qos: .userInitiated))

            let tempID = UInt32.random(in: 1..<UInt32.max)
            await self.addConnection(connection, taskID: tempID)
        }
    }

    private func addConnection(_ connection: NWConnection, taskID: UInt32) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleConnection(connection, taskID: taskID)
        }
        
        connectionTasks[taskID] = task
        activeConnectionCount += 1
    }

    private func validateEndpoint(_ endpoint: NWEndpoint) async -> Bool {
        let sameSubnetOnly = await MainActor.run { settings.sameSubnetOnly }
        let validateIP = await MainActor.run { settings.validateRemoteIP }
        guard sameSubnetOnly || validateIP else { return true }

        guard case let .hostPort(host, _) = endpoint else { return false }
        
        var remoteIPString = ""
        switch host {
        case .ipv4(let ipv4): remoteIPString = "\(ipv4)"
        case .ipv6(let ipv6): remoteIPString = "\(ipv6)"
        case .name(let name, _): remoteIPString = name
        @unknown default: return false
        }

        if sameSubnetOnly {
            if !isSameSubnet(remoteIPString) {
                mwbWarning(MWBLog.network,"ServerListener: Security rejection: \(remoteIPString) is not in the same subnet")
                return false
            }
        }

        if validateIP {
            // Reverse DNS check will be performed after handshake when we have the remote machine name
            // For now we just allow the connection to proceed to handshake
        }

        return true
    }

    private func validateReverseDNS(connection: NWConnection, expectedName: String) async -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        
        var ipString = ""
        switch host {
        case .ipv4(let ipv4): ipString = "\(ipv4)"
        case .ipv6(let ipv6): ipString = "\(ipv6)"
        case .name(let name, _): ipString = name
        @unknown default: return false
        }

        return await withCheckedContinuation { continuation in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            
            var res: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(ipString, nil, &hints, &res) == 0, let res = res {
                defer { freeaddrinfo(res) }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(res.pointee.ai_addr, res.pointee.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NAMEREQD) == 0 {
                    let nullIdx = hostname.firstIndex(of: 0) ?? hostname.endIndex
                    let reversedName = String(decoding: hostname[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    // Match case-insensitively and ignore domain if provided
                    let remoteBaseName = expectedName.split(separator: ".")[0].lowercased()
                    let reversedBaseName = reversedName.split(separator: ".")[0].lowercased()
                    
                    if remoteBaseName == reversedBaseName {
                        continuation.resume(returning: true)
                        return
                    }
                    mwbWarning(MWBLog.network,"ServerListener: DNS mismatch: expected \(remoteBaseName), got \(reversedBaseName)")
                }
            }
            continuation.resume(returning: false)
        }
    }

    private func isSameSubnet(_ remoteIP: String) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return true } // Fallback to allow if we can't check
        defer { freeifaddrs(ifaddr) }

        let remoteParts = remoteIP.split(separator: ".")
        guard remoteParts.count == 4 else { return true } // Only IPv4 for this simple check

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let flags = Int32(interface.ifa_flags)
            let addr = interface.ifa_addr.pointee

            // Check for IPv4 and skip loopback
            if addr.sa_family == UInt8(AF_INET) && (flags & IFF_LOOPBACK) == 0 && (flags & IFF_UP) != 0 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let nullIdx = hostname.firstIndex(of: 0) ?? hostname.endIndex
                let localIP = String(decoding: hostname[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let localParts = localIP.split(separator: ".")
                
                if localParts.count == 4 {
                    // Windows MWB style: first two octets must match
                    if localParts[0] == remoteParts[0] && localParts[1] == remoteParts[1] {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: Per-Connection Lifecycle

    private func handleConnection(_ connection: NWConnection, taskID: UInt32) async {
        defer {
            connection.cancel()
            mwbInfo(MWBLog.network,"ServerListener: connection closed")
            Task { [weak self] in
                await self?.connectionDidClose(taskID: taskID)
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
            mwbError(MWBLog.network,"ServerListener: outbound noise exchange failed: \(error.localizedDescription)")
            return
        }

        // Phase 2: Send 10 handshake challenges (matching PowerToys MainTCPRoutine)
        handshakeHandler.start()
        do {
            try await sendHandshakeChallenges(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
        } catch {
            mwbError(MWBLog.network,"ServerListener: send challenges failed: \(error.localizedDescription)")
            return
        }

        // Phase 3: Receive pump (handles incoming HandshakeAck verification and all other packets)
        mwbInfo(MWBLog.network,"ServerListener: entering receive pump")
        
        connections[taskID] = (connection, crypto, magicHash)
        
        await receivePump(connection, crypto: crypto, magicHash: magicHash, handler: &handshakeHandler)
    }

    private func connectionDidClose(taskID: UInt32) {
        activeConnectionCount = max(0, activeConnectionCount - 1)
        connectionTasks.removeValue(forKey: taskID)
        connections.removeValue(forKey: taskID)
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
            if localMachineID != .none {
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
                    mwbInfo(MWBLog.network,"ServerListener receive pump: connection closed")
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
                        mwbWarning(MWBLog.network,"ServerListener receive pump: incomplete big packet")
                        break
                    }

                    let secondDecrypted = crypto.decrypt(padToBlock(secondData))
                    fullData = firstDecrypted + secondDecrypted
                } else {
                    fullData = firstDecrypted
                }

                let packet = MWBPacket(rawData: fullData)

                guard packet.validateChecksum() else {
                    mwbWarning(MWBLog.network,"ServerListener: invalid checksum, skipping packet")
                    continue
                }
                guard packet.validateMagic(magicHash) else {
                    mwbWarning(MWBLog.network,"ServerListener: invalid magic, skipping packet")
                    continue
                }

                // Handle re-handshake and heartbeat echo inline; dispatch everything else
                if await handleSpecialPacket(packet, connection: conn, crypto: crypto, magicHash: magicHash, handler: &handler) {
                    continue
                }

                dispatchPacket(packet)

            } catch {
                mwbError(MWBLog.network,"ServerListener receive pump error: \(error.localizedDescription)")
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
    ) async -> Bool {
        guard let type = packet.packageType else { return false }

        switch type {
        case .handshake:
            // Re-handshake during active session: respond with type 127
            handleRehandshake(packet, connection: connection, crypto: crypto, magicHash: magicHash, handler: &handler)
            return true

        case .handshakeAck:
            // Received response to our challenge: mark as trusted and store remote ID
            let remoteName = packet.machineName
            let validateIP = await MainActor.run { settings.validateRemoteIP }
            
            if validateIP {
                if await !validateReverseDNS(connection: connection, expectedName: remoteName) {
                    mwbWarning(MWBLog.network,"ServerListener: Reverse DNS validation failed for \(remoteName)")
                    connection.cancel()
                    return true
                }
            }

            self.remoteMachineID = packet.src
            mwbInfo(MWBLog.network,"ServerListener: received handshakeAck from machine \(packet.src) (\(remoteName)), connection trusted")
            return true

        case .heartbeat, .heartbeatEx, .heartbeatExL2, .heartbeatExL3:
            // Key agreement protocol: respond with the appropriate next level
            respondToHeartbeat(packet, connection: connection, crypto: crypto, magicHash: magicHash, machineID: handler.adoptedMachineID)
            return true

        case .awake:
            // Prevent display sleep as requested by remote activity
            await PowerManager.shared.poke()
            // Respond as if it were a standard heartbeat for protocol flow
            respondToHeartbeat(packet, connection: connection, crypto: crypto, magicHash: magicHash, machineID: handler.adoptedMachineID)
            return true

        case .explorerDragDrop:
            Task { @MainActor in
                DragDropManager.shared.handleExplorerDragDropRequest()
            }
            return true
            
        case .clipboardDragDrop:
            Task { @MainActor in
                DragDropManager.shared.handleRemoteDragAnnounced()
            }
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
        guard var ack = handler.receiveChallenge(packet, localMachineName: localMachineName, localMachineID: localMachineID) else { return }
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
        machineID: MachineID
    ) {
        guard let type = packet.packageType else { return }

        let responseType: PackageType
        switch type {
        case .heartbeat, .heartbeatEx:
            responseType = .heartbeatExL2
            mwbInfo(MWBLog.network,"ServerListener: received heartbeat type \(type.rawValue), sending heartbeatExL2")
        case .heartbeatExL2:
            responseType = .heartbeatExL3
            mwbInfo(MWBLog.network,"ServerListener: received heartbeatExL2, sending heartbeatExL3")
        case .heartbeatExL3:
            mwbInfo(MWBLog.network,"ServerListener: received heartbeatExL3, key agreement complete")
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
                mwbDebug(MWBLog.network, "ServerListener dedup: dropping duplicate packet id=\(packet.id)")
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

        case .matrix:
            let nameBytes = packet.data[16..<48]
            guard let name = String(data: Data(nameBytes), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) else { break }
            
            MachinePool.shared.updateMachineMatrix(packetType: packet.type, src: packet.src, machineName: name)
            
            if packet.src.rawValue == 4 {
                // Packet 4 is the final packet. Flags were handled in updateMachineMatrix.
                let matrixCircle = MachinePool.shared.matrixCircle
                let matrixOneRow = MachinePool.shared.matrixOneRow
                let newMatrixStr = MachinePool.shared.machineMatrix.joined(separator: ",")
                
                Task {
                    await MainActor.run {
                        settings.machineMatrixString = newMatrixStr
                        settings.matrixCircle = matrixCircle
                        settings.matrixOneRow = matrixOneRow
                    }
                    mwbInfo(MWBLog.network,"ServerListener: Committed new matrix from remote: \(newMatrixStr)")
                }
            }

        case .clipboard, .clipboardText, .clipboardImage, .clipboardDataEnd,
             .clipboardAsk, .clipboardPush, .clipboardDragDrop, .clipboardDragDropEnd:
            onClipboard?(packet)

        case .byeBye:
            mwbInfo(MWBLog.network,"Received ByeBye packet, disconnecting")
            // ServerListener doesn't maintain state, just log it

        case .hi:
            mwbInfo(MWBLog.network,"Received Hi packet")

        default:
            break
        }
    }

    /// Sends a ByeBye packet to all active inbound connections.
    func sendByeBye() async {
        let activeConns = Array(connections.values)
        
        for (conn, crypto, magicHash) in activeConns {
            var packet = MWBPacket()
            packet.type = PackageType.byeBye.rawValue
            packet.src = localMachineID
            packet.des = MWBConstants.broadcastDestination
            packet.id = nextPacketID
            nextPacketID &+= 1

            let nameData = HandshakeHandler.encodeMachineName(localMachineName)
            var fullData = packet.data
            fullData.replaceSubrange(16..<48, with: nameData)
            packet.data = fullData

            packet.setMagic(magicHash)
            _ = packet.computeChecksum()
            
            let data = packet.transmittedData
            let encrypted = crypto.encrypt(padToBlock(data))
            
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

    /// Pad data to AES block size (16 bytes) with zero bytes.
    private func padToBlock(_ data: Data) -> Data {
        let remainder = data.count % MWBConstants.ivLength
        if remainder == 0 { return data }
        return data + Data(count: MWBConstants.ivLength - remainder)
    }
}
