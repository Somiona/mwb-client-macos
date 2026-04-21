import AppKit
import Foundation
import Network
import os.log
import Security

// MARK: - Clipboard Manager

actor ClipboardManager {

    // MARK: Public State

    private(set) var isConnected = false

    // MARK: Configuration

    private let host: String
    private let port: UInt16
    private let securityKey: String
    private let localMachineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16

    /// Whether to sync text clipboard content.
    private var syncText: Bool

    /// Whether to sync image clipboard content.
    private var syncImages: Bool

    /// Whether to sync file clipboard content.
    private var syncFiles: Bool

    // MARK: Crypto & Protocol State

    private var crypto: MWBCrypto
    private var handshakeHandler = HandshakeHandler()
    private var magicHash: UInt32 = 0

    // MARK: Connection

    private var connection: NWConnection?
    private var connectionTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: Feedback Loop Prevention

    /// The NSPasteboard changeCount after we write clipboard content from the remote.
    /// Changes with this count (or earlier) are ignored on the next poll to prevent
    /// echoing back data we just received.
    private var lastWriteChangeCount: Int = 0

    /// The changeCount we last observed and sent outbound.
    /// Prevents sending the same content twice.
    private var lastSentChangeCount: Int = 0

    // MARK: Inbound Accumulation

    /// Packets accumulated for the current inbound clipboard transfer.
    private var inboundPackets: [MWBPacket] = []

    /// The type of clipboard content currently being received.
    private var inboundContentType: PackageType?

    // MARK: Init

    init(
        host: String,
        port: UInt16 = MWBConstants.clipboardPort,
        securityKey: String,
        machineName: String = Host.current().localizedName ?? "Mac",
        screenWidth: UInt16 = UInt16(NSScreen.main?.frame.width ?? 1920),
        screenHeight: UInt16 = UInt16(NSScreen.main?.frame.height ?? 1080),
        syncText: Bool = true,
        syncImages: Bool = true,
        syncFiles: Bool = true
    ) {
        self.host = host
        self.port = port
        self.securityKey = securityKey
        self.localMachineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.syncText = syncText
        self.syncImages = syncImages
        self.syncFiles = syncFiles
        self.crypto = MWBCrypto(securityKey: securityKey)
        self.magicHash = crypto.get24BitHash()
    }

    // MARK: Start / Stop

    func start() {
        guard !isConnected else { return }
        Logger.clipboard.info("ClipboardManager starting, connecting to \(self.host):\(self.port)")
        connect()
    }

    func stop() {
        Logger.clipboard.info("ClipboardManager stopping")
        pollTask?.cancel()
        pollTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // MARK: Settings Updates

    func updateSyncSettings(syncText: Bool? = nil, syncImages: Bool? = nil, syncFiles: Bool? = nil) {
        if let syncText { self.syncText = syncText }
        if let syncImages { self.syncImages = syncImages }
        if let syncFiles { self.syncFiles = syncFiles }
    }

    func updateHost(_ newHost: String) {
        // Host is immutable per connection lifecycle; call stop + start to change.
    }

    // MARK: Connect

    private func connect() {
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }

        connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        guard let conn = connection else { return }

        conn.start(queue: .global(qos: .userInitiated))

        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectionSequence()
        }
    }

    // MARK: Connection Sequence

    private func runConnectionSequence() async {
        guard let conn = connection else {
            isConnected = false
            return
        }

        // Wait for TCP connection to establish
        do {
            try await waitForConnection(conn)
        } catch {
            Logger.clipboard.error("Clipboard connection failed: \(error.localizedDescription)")
            scheduleReconnect()
            return
        }

        // Phase 1: Noise exchange
        do {
            try await exchangeNoise(conn)
        } catch {
            Logger.clipboard.error("Clipboard noise exchange failed: \(error.localizedDescription)")
            scheduleReconnect()
            return
        }

        // Phase 2: Handshake
        handshakeHandler.start()
        do {
            try await performHandshake(conn)
        } catch {
            Logger.clipboard.error("Clipboard handshake failed: \(error.localizedDescription)")
            scheduleReconnect()
            return
        }

        // Phase 3: Send identity
        do {
            try await sendIdentity(conn)
        } catch {
            Logger.clipboard.error("Clipboard send identity failed: \(error.localizedDescription)")
            scheduleReconnect()
            return
        }

        // Phase 4: Connected
        isConnected = true
        Logger.clipboard.info("Clipboard connected")
        startPollLoop()

        // Phase 5: Receive pump (blocks until disconnect)
        await receivePump(conn)

        // Cleanup after pump exits
        isConnected = false
        pollTask?.cancel()
        pollTask = nil
        scheduleReconnect()
    }

    private func waitForConnection(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
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
        let receivedNoise = try await conn.receive(
            minimumIncompleteLength: MWBConstants.noiseSize,
            maximumLength: MWBConstants.noiseSize
        )
        guard let noiseData = receivedNoise, noiseData.count == MWBConstants.noiseSize else {
            throw NetworkError.invalidNoise
        }
        _ = crypto.decrypt(padToBlock(noiseData))
    }

    // MARK: Handshake

    private func performHandshake(_ conn: NWConnection) async throws {
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

            guard var ackPacket = handshakeHandler.receiveChallenge(challengePacket) else {
                throw NetworkError.handshakeFailed("handshake handler rejected challenge")
            }
            ackPacket.setMagic(magicHash)
            _ = ackPacket.computeChecksum()

            let ackEncrypted = crypto.encrypt(padToBlock(ackPacket.transmittedData))
            try await conn.send(content: ackEncrypted)
        }

        guard handshakeHandler.completeIfReady() else {
            throw NetworkError.handshakeFailed(
                "handshake not complete after \(MWBConstants.handshakeIterationCount) iterations"
            )
        }
    }

    // MARK: Identity

    private func sendIdentity(_ conn: NWConnection) async throws {
        let id = handshakeHandler.adoptedMachineID != 0 ? handshakeHandler.adoptedMachineID : 0
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
                let firstChunk = try await conn.receive(
                    minimumIncompleteLength: MWBConstants.smallPacketSize,
                    maximumLength: MWBConstants.smallPacketSize
                )

                guard let firstData = firstChunk, firstData.count == MWBConstants.smallPacketSize else {
                    Logger.clipboard.info("Clipboard receive pump: connection closed")
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
                        Logger.clipboard.warning("Clipboard receive pump: incomplete big packet")
                        break
                    }

                    let secondDecrypted = crypto.decrypt(padToBlock(secondData))
                    fullData = firstDecrypted + secondDecrypted
                } else {
                    fullData = firstDecrypted
                }

                let packet = MWBPacket(rawData: fullData)

                guard packet.validateChecksum() else {
                    Logger.clipboard.warning("Clipboard: invalid checksum, skipping packet")
                    continue
                }
                guard packet.validateMagic(magicHash) else {
                    Logger.clipboard.warning("Clipboard: invalid magic, skipping packet")
                    continue
                }

                handleIncomingPacket(packet)

            } catch {
                Logger.clipboard.error("Clipboard receive pump error: \(error.localizedDescription)")
                break
            }
        }
    }

    // MARK: Incoming Packet Handling

    private func handleIncomingPacket(_ packet: MWBPacket) {
        guard let type = packet.packageType else { return }

        switch type {
        case .clipboardText:
            // Start accumulating text clipboard data
            inboundContentType = .clipboardText
            inboundPackets.append(packet)

        case .clipboardImage:
            // Start accumulating image clipboard data
            inboundContentType = .clipboardImage
            inboundPackets.append(packet)

        case .clipboardDataEnd:
            // End of clipboard stream - process accumulated data
            processInboundClipboard()
            inboundPackets.removeAll()
            inboundContentType = nil

        case .clipboard:
            // Type 69: clipboard notification (used for file/big clipboard paths)
            inboundContentType = .clipboard
            inboundPackets.append(packet)

        case .handshake:
            // Re-handshake during active session
            handleRehandshake(packet)

        case .heartbeat, .heartbeatEx, .heartbeatExL2, .heartbeatExL3:
            // Echo heartbeat back on clipboard channel
            echoHeartbeat(packet)

        default:
            break
        }
    }

    // MARK: Process Inbound Clipboard

    private func processInboundClipboard() {
        guard !inboundPackets.isEmpty else { return }

        switch inboundContentType {
        case .clipboardText:
            guard syncText else { return }
            if let text = ClipboardCodec.decodeText(from: inboundPackets) {
                Logger.clipboard.info("Received text clipboard (\(text.count) chars)")
                writeTextToPasteboard(text)
            } else {
                Logger.clipboard.error("Failed to decode text clipboard from \(self.inboundPackets.count) packets")
            }

        case .clipboardImage:
            guard syncImages else { return }
            if let imageData = ClipboardCodec.decodeImage(from: inboundPackets) {
                Logger.clipboard.info("Received image clipboard (\(imageData.count) bytes)")
                writeImageToPasteboard(imageData)
            } else {
                Logger.clipboard.error("Failed to decode image clipboard from \(self.inboundPackets.count) packets")
            }

        case .clipboard:
            // File clipboard via type 69 - not yet implemented for full file transfer.
            // The dedicated clipboard TCP path for files would use the raw stream
            // header format described in the MWB protocol. For now, skip.
            break

        default:
            break
        }
    }

    // MARK: Write to Pasteboard

    private func writeTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if success {
            lastWriteChangeCount = pasteboard.changeCount
        } else {
            Logger.clipboard.error("Failed to write text to pasteboard")
        }
    }

    private func writeImageToPasteboard(_ data: Data) {
        guard let image = NSImage(data: data) else {
            Logger.clipboard.error("Failed to create NSImage from clipboard data")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([image])
        if success {
            lastWriteChangeCount = pasteboard.changeCount
        } else {
            Logger.clipboard.error("Failed to write image to pasteboard")
        }
    }

    // MARK: Re-handshake

    private func handleRehandshake(_ packet: MWBPacket) {
        guard var ack = handshakeHandler.receiveChallenge(packet) else { return }
        ack.setMagic(magicHash)
        _ = ack.computeChecksum()

        guard let conn = connection else { return }
        let encrypted = crypto.encrypt(padToBlock(ack.transmittedData))
        conn.send(content: encrypted, completion: .contentProcessed({ _ in }))
    }

    // MARK: Heartbeat Echo

    private func echoHeartbeat(_ packet: MWBPacket) {
        var response = MWBPacket()
        response.type = PackageType.heartbeatExL2.rawValue
        response.id = packet.id
        response.src = packet.des
        response.des = packet.src
        response.data = packet.data
        response.setMagic(magicHash)
        _ = response.computeChecksum()

        guard let conn = connection else { return }
        let encrypted = crypto.encrypt(padToBlock(response.transmittedData))
        conn.send(content: encrypted, completion: .contentProcessed({ _ in }))
    }

    // MARK: Outbound Poll Loop

    private func startPollLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollPasteboard()
        }
    }

    private func pollPasteboard() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(MWBConstants.clipboardPollInterval * 1_000_000_000)
                )
            } catch {
                break // Cancelled
            }

            guard !Task.isCancelled else { break }
            guard isConnected else { break }

            checkAndSendClipboard()
        }
    }

    private let maxClipboardDataSize = 10 * 1024 * 1024 // 10 MB

    private func checkAndSendClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // Skip if no change, or if this is a change we ourselves wrote (feedback loop)
        guard currentCount != lastSentChangeCount else { return }
        guard currentCount > lastWriteChangeCount else { return }

        // Priority: text > image > files
        if syncText, let text = readTextFromPasteboard() {
            if text.utf16.count > maxClipboardDataSize {
                Logger.clipboard.warning("Text clipboard too large (\(text.utf16.count) bytes), skipping")
                lastSentChangeCount = currentCount
                return
            }
            Logger.clipboard.info("Sending text clipboard (\(text.count) chars)")
            sendTextClipboard(text)
            lastSentChangeCount = currentCount
            return
        }

        if syncImages, let imageData = readImageFromPasteboard() {
            if imageData.count > maxClipboardDataSize {
                Logger.clipboard.warning("Image clipboard too large (\(imageData.count) bytes), skipping")
                lastSentChangeCount = currentCount
                return
            }
            Logger.clipboard.info("Sending image clipboard (\(imageData.count) bytes)")
            sendImageClipboard(imageData)
            lastSentChangeCount = currentCount
            return
        }

        if syncFiles {
            // File clipboard sync via dedicated TCP path is a future enhancement.
            // The clipboard TCP channel for files requires the raw stream header
            // format ("{fileSize}*{fileName}") followed by file data in 1MB chunks.
        }
    }

    // MARK: Read from Pasteboard

    private func readTextFromPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func readImageFromPasteboard() -> Data? {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard) else {
            return nil
        }

        guard let tiffData = image.tiffRepresentation else {
            Logger.clipboard.error("Failed to get TIFF representation from pasteboard image")
            return nil
        }

        guard let bitmap = NSBitmapImageRep(data: tiffData) else {
            Logger.clipboard.error("Failed to create NSBitmapImageRep from TIFF data")
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Send Clipboard

    private func sendTextClipboard(_ text: String) {
        guard let conn = connection, isConnected else { return }

        let packets = ClipboardCodec.encodeText(text)
        Logger.clipboard.debug("Sending text clipboard in \(packets.count) packets")
        for packet in packets {
            var mutablePacket = packet
            mutablePacket.setMagic(magicHash)
            _ = mutablePacket.computeChecksum()

            let encrypted = crypto.encrypt(padToBlock(mutablePacket.transmittedData))
            conn.send(content: encrypted, completion: .contentProcessed { error in
                if let error {
                    Logger.clipboard.error("Failed to send clipboard packet: \(error.localizedDescription)")
                }
            })
        }
    }

    private func sendImageClipboard(_ data: Data) {
        guard let conn = connection, isConnected else { return }

        let packets = ClipboardCodec.encodeImage(data)
        Logger.clipboard.debug("Sending image clipboard in \(packets.count) packets")
        for packet in packets {
            var mutablePacket = packet
            mutablePacket.setMagic(magicHash)
            _ = mutablePacket.computeChecksum()

            let encrypted = crypto.encrypt(padToBlock(mutablePacket.transmittedData))
            conn.send(content: encrypted, completion: .contentProcessed { error in
                if let error {
                    Logger.clipboard.error("Failed to send clipboard packet: \(error.localizedDescription)")
                }
            })
        }
    }

    // MARK: Reconnect

    private func scheduleReconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false

        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(MWBConstants.reconnectDelay * 1_000_000_000))
            } catch {
                return
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
}
