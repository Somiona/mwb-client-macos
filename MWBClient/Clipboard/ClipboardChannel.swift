import Foundation
import Network
import os.log
import Security

/// Post-action requested for data received over the clipboard channel,
/// mirroring the PowerToys `ClipboardPostAction` enum (sent as the uint at
/// data offset 0 of the handshake packet).
enum ClipboardPostAction: UInt32, Sendable {
    case other = 0
    case desktop = 1
    case mspaint = 2

    var wireName: String {
        switch self {
        case .other: return "Other"
        case .desktop: return "desktop"
        case .mspaint: return "mspaint"
        }
    }
}

// MARK: - Clipboard Channel

/// Actor owning all port-15100 (clipboard channel) traffic: the secondary
/// TCP channel PowerToys uses for large clipboard payloads (> 1 MB) and file
/// transfers, so the primary input socket stays unblocked.
///
/// Mirrors the reference `SocketStuff.SendOrReceiveClipboardData` /
/// `Clipboard.ShakeHand` / `Clipboard.ReceiveAndProcessClipboardData`:
///
/// - Per connection: one fresh ``MWBCrypto`` (stateful CBC IV chaining), a
///   16-byte encrypted random block exchanged in each direction, then one
///   64-byte header packet (`Type` = 69 when pulling / 79 when pushing,
///   `PostAction` at data offset 0, `Src`, `MachineName` at data offset 16).
///   The peer's `Type` decides the direction: 79 → the peer pushes (we
///   receive), 69 → the peer pulls (we serve).
/// - Transfer framing: a 1024-byte UTF-16LE `"{size}*{name}"` header
///   zero-padded, followed by the body zero-padded to a 32-byte multiple.
///   The receiver trims to exactly `size` bytes.
actor ClipboardChannel {

    // MARK: - Errors

    enum ChannelError: Error, LocalizedError {
        case cancelled
        case handshakeFailed(String)
        case badHeader
        case shortRead(received: Int64, expected: Int64)
        case noRemoteHost

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "connection cancelled"
            case .handshakeFailed(let why):
                return "handshake failed: \(why)"
            case .badHeader:
                return "invalid transfer header"
            case .shortRead(let received, let expected):
                return "short read: got \(received) of \(expected) bytes"
            case .noRemoteHost:
                return "no remote host configured"
            }
        }
    }

    // MARK: - Pending data

    /// Large clipboard data staged for the next pull by the remote machine.
    /// Mirrors `Clipboard.LastClipboardData` / `Clipboard.LastDragDropFile`.
    enum PendingData: Sendable {
        /// Deflate-compressed UTF-16LE text payload.
        case text(Data)
        /// PNG bytes.
        case image(Data)
        /// A regular file on disk, streamed from disk when served.
        case file(URL)
        /// A directory: the peer gets a "not supported" header.
        case directory(String)
        /// A file over the 100 MB cap: the peer gets a "too big" header.
        case fileTooBig(String)
    }

    // MARK: - Configuration

    private let securityKey: String
    private var machineID: MachineID
    private var machineName: String

    /// Host and display name of the remote machine, set by the coordinator
    /// once the main-socket connection is established.
    private var remoteHost = ""
    private var remoteName = ""

    // MARK: - State

    /// TCP port for the listener and outbound connections. Defaults to the
    /// PowerToys clipboard port (15100); 0 binds an ephemeral port (tests).
    private let port: UInt16

    /// The actually bound port (set when the listener becomes ready; an
    /// ephemeral bind resolves to the assigned port here).
    private(set) var listeningPort: UInt16?

    private var listener: NWListener?
    private(set) var isListening = false
    private var connectionTasks: [Task<Void, Never>] = []

    /// Guards concurrent inbound transfers (the reference rejects a second
    /// concurrent receive with `ExecuteClipboardReceive`).
    private var isTransferring = false

    /// Large clipboard data staged by ``ClipboardManager``.
    private(set) var pendingData: PendingData?

    /// File staged by an in-progress local drag; takes precedence over
    /// ``pendingData`` when serving.
    private(set) var pendingDragFile: String?

    // MARK: - Callbacks (wired by AppCoordinator)

    var onReceivedText: (@Sendable (ClipboardCodec.DecodedClipboardText) async -> Void)?
    var onReceivedImage: (@Sendable (Data) async -> Void)?
    var onReceivedFile: (@Sendable (URL, ClipboardPostAction) async -> Void)?
    /// Invoked whenever a clipboard-channel connection is accepted, so drag
    /// and drop state can be reset (reference `SendOrReceiveClipboardData`).
    var onConnectionAccepted: (@Sendable () async -> Void)?

    /// Sets all channel callbacks in a single actor-isolated call.
    func setCallbacks(
        onReceivedText: (@Sendable (ClipboardCodec.DecodedClipboardText) async -> Void)?,
        onReceivedImage: (@Sendable (Data) async -> Void)?,
        onReceivedFile: (@Sendable (URL, ClipboardPostAction) async -> Void)?,
        onConnectionAccepted: (@Sendable () async -> Void)?
    ) {
        self.onReceivedText = onReceivedText
        self.onReceivedImage = onReceivedImage
        self.onReceivedFile = onReceivedFile
        self.onConnectionAccepted = onConnectionAccepted
    }

    // MARK: - Init

    init(
        securityKey: String,
        machineID: MachineID,
        machineName: String,
        port: UInt16 = MWBConstants.clipboardPort
    ) {
        self.securityKey = securityKey
        self.machineID = machineID
        self.machineName = machineName
        self.port = port
    }

    // MARK: - Identity updates

    func updateIdentity(machineID: MachineID, machineName: String) {
        self.machineID = machineID
        self.machineName = machineName
    }

    func updateRemote(host: String, name: String) {
        self.remoteHost = host
        self.remoteName = name
    }

    // MARK: - Pending data staging

    /// Replaces the data staged for the next pull/push. Replacing staged
    /// data while a transfer is already in flight does NOT affect it:
    /// `serveFile` streams from a path captured when the serve started and
    /// never re-reads `pendingData`, so a mid-transfer clipboard change can
    /// only redirect the NEXT transfer (latest copy wins), never truncate or
    /// corrupt the one on the wire.
    func setPendingData(_ data: PendingData?) {
        pendingData = data
    }

    func setPendingDragFile(_ path: String?) {
        pendingDragFile = path
    }

    // MARK: - Listener lifecycle

    func start() async {
        guard !isListening else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let parameters = NWParameters(tls: nil, tcp: Self.makeTCPOptions())

        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            // Port already in use: keep inline clipboard sync working, only
            // the large-data/file channel is disabled.
            mwbError(MWBLog.clipboard, "Clipboard channel: cannot listen on port \(port): \(error.localizedDescription)")
            return
        }

        guard let listener else { return }

        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleAcceptedConnection(connection)
            }
        }

        // Wait until the listener is ready (or has failed) so callers can
        // rely on `isListening` / `listeningPort` right after start().
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let flag = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] newState in
                Task { [weak self] in
                    await self?.handleListenerState(newState)
                    guard !flag.fired else { return }
                    switch newState {
                    case .ready, .failed, .cancelled:
                        flag.fired = true
                        continuation.resume()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        if isListening {
            mwbInfo(MWBLog.clipboard, "Clipboard channel listening on port \(listeningPort.map(String.init) ?? String(port))")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
        for task in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()
        pendingData = nil
        pendingDragFile = nil
        isTransferring = false
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            if let bound = listener?.port?.rawValue {
                listeningPort = bound
            }
        case .failed(let error):
            isListening = false
            mwbError(MWBLog.clipboard, "Clipboard channel listener failed: \(error.localizedDescription)")
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: - Inbound connections (Mac serves or receives)

    private func handleAcceptedConnection(_ connection: NWConnection) {
        // Reset drag & drop state, mirroring the reference accept path.
        let reset = onConnectionAccepted
        let task = Task { [weak self] in
            await reset?()
            await self?.runConnection(
                connection,
                ourType: PackageType.clipboardPush.rawValue,
                postAction: .other,
                role: .server)
        }
        connectionTasks.append(task)
    }

    /// Who drives the transfer on a clipboard-channel connection. The
    /// direction of an OUTBOUND connection is fixed by our intent and must
    /// not be inferred from the peer's handshake type: the reference server
    /// always announces `ClipboardPush` (79) initially (its `clientPushData`
    /// starts true), so a pusher reading 79 would wrongly try to receive.
    /// Only the server infers the direction from the peer's type (69 = the
    /// peer pulls, 79 = the peer pushes).
    private enum TransferRole {
        /// Outbound pull: the remote serves, we receive.
        case puller
        /// Outbound push (ClipboardAsk response): we serve our staged data.
        case pusher
        /// Inbound connection: the peer's handshake type decides.
        case server
    }

    // MARK: - Outbound connections (Mac pulls or pushes)

    /// Pulls the remote machine's large clipboard data. Our handshake type is
    /// 69 (`Clipboard`); the remote answers 79 and sends the data.
    func pull(postAction: ClipboardPostAction) async {
        await runOutboundConnection(
            ourType: PackageType.clipboard.rawValue, postAction: postAction, role: .puller)
    }

    /// Serves our staged clipboard data to the remote machine. Used when the
    /// remote sends `ClipboardAsk` (78) and cannot connect to us directly:
    /// we connect out with handshake type 79 (`ClipboardPush`) and send,
    /// echoing the ask's post action (reference `PackageType.ClipboardAsk`
    /// handler passes `package.PostAction` through to `ShakeHand`).
    func pushPendingData(postAction: ClipboardPostAction) async {
        await runOutboundConnection(
            ourType: PackageType.clipboardPush.rawValue, postAction: postAction, role: .pusher)
    }

    private func runOutboundConnection(ourType: UInt8, postAction: ClipboardPostAction, role: TransferRole) async {
        guard !remoteHost.isEmpty else {
            mwbWarning(MWBLog.clipboard, "Clipboard channel: no remote host, skipping \(ourType == PackageType.clipboard.rawValue ? "pull" : "push")")
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: MWBConstants.clipboardPort)!,
            using: NWParameters(tls: nil, tcp: Self.makeTCPOptions())
        )

        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }

        do {
            try await Self.waitForReady(connection)
            let weServed = try await runHandshakeAndTransfer(
                connection, ourType: ourType, postAction: postAction, role: role)
            if weServed {
                // We sent the data: wait for the peer's close so everything
                // is delivered before cancel() (reference Socket.Close(10)
                // linger semantics).
                await waitForPeerClose(connection, timeout: Self.closeTimeout)
            }
        } catch {
            mwbWarning(MWBLog.clipboard, "Clipboard channel outbound failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection handling

    private func runConnection(_ connection: NWConnection, ourType: UInt8, postAction: ClipboardPostAction, role: TransferRole) async {
        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }
        do {
            let weServed = try await runHandshakeAndTransfer(
                connection, ourType: ourType, postAction: postAction, role: role)
            if weServed {
                await waitForPeerClose(connection, timeout: Self.closeTimeout)
            }
        } catch {
            mwbWarning(MWBLog.clipboard, "Clipboard channel connection failed: \(error.localizedDescription)")
        }
    }

    /// Runs the handshake and the transfer. Returns true when this side sent
    /// the data (the caller then waits for the peer's close before
    /// cancelling).
    private func runHandshakeAndTransfer(
        _ connection: NWConnection,
        ourType: UInt8,
        postAction: ClipboardPostAction,
        role: TransferRole
    ) async throws -> Bool {
        let crypto = MWBCrypto(securityKey: securityKey)
        let peer = try await handshake(connection, crypto: crypto, ourType: ourType, postAction: postAction)

        switch role {
        case .pusher:
            // ClipboardAsk response: we serve unconditionally (reference
            // always calls SendClipboardData after this handshake).
            return try await serveTransfer(connection, crypto: crypto)
        case .puller:
            // Outbound pull: the remote serves, we receive.
            try await receiveTransfer(connection, crypto: crypto, postAction: peer.postAction)
            return false
        case .server:
            if peer.isPusher {
                // Peer pushes data to us; we close as soon as we have it all.
                try await receiveTransfer(connection, crypto: crypto, postAction: peer.postAction)
                return false
            } else {
                // Peer pulls data from us.
                return try await serveTransfer(connection, crypto: crypto)
            }
        }
    }

    /// Waits until the peer closes the connection (EOF) or `timeout`
    /// elapses. Senders use this so their final message is fully delivered
    /// before the connection is cancelled.
    private func waitForPeerClose(_ connection: NWConnection, timeout: TimeInterval) async {
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.fire() {
                    continuation.resume()
                }
            }
            Task {
                defer { timeoutTask.cancel() }
                while true {
                    do {
                        guard
                            let data = try await connection.receive(
                                minimumIncompleteLength: 1,
                                maximumLength: Self.chunkSize),
                            !data.isEmpty
                        else {
                            break
                        }
                    } catch {
                        break
                    }
                }
                if once.fire() {
                    continuation.resume()
                }
            }
        }
    }

    private struct PeerInfo: Sendable {
        let isPusher: Bool
        let postAction: ClipboardPostAction
    }

    /// Performs the clipboard-channel handshake. Both sides first exchange a
    /// 16-byte encrypted random block (discarded), then one 64-byte packet.
    /// The peer's `Type` decides the transfer direction: `ClipboardPush` (79)
    /// means the peer sends data, `Clipboard` (69) means the peer wants ours.
    private func handshake(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        ourType: UInt8,
        postAction: ClipboardPostAction
    ) async throws -> PeerInfo {
        // 0. Send the 32-byte cleartext salt+IV stream header first
        //    (PowerToys v0.101.2211+: Encryption.GetEncryptedStream).
        try await connection.send(content: crypto.makeOutboundHeader())

        // 1. Send our random block.
        var noise = Data(count: MWBConstants.noiseSize)
        _ = noise.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, MWBConstants.noiseSize, ptr.baseAddress!)
        }
        try await connection.send(content: crypto.encrypt(noise))

        // 2. Send our header packet.
        var packet = MWBPacket()
        packet.type = ourType
        packet.src = machineID
        packet.machineName = machineName
        packet.setDataUInt32(postAction.rawValue, at: 0)
        try await connection.send(content: crypto.encrypt(packet.transmittedData))

        // 3. Receive the peer's 32-byte cleartext salt+IV stream header
        //    (PowerToys v0.101.2211+: Encryption.GetDecryptedStream).
        guard
            let peerStreamHeader = try await connection.receive(
                minimumIncompleteLength: MWBConstants.streamHeaderSize,
                maximumLength: MWBConstants.streamHeaderSize),
            peerStreamHeader.count == MWBConstants.streamHeaderSize
        else {
            throw ChannelError.handshakeFailed("short encryption header")
        }
        crypto.processInboundHeader(peerStreamHeader)

        // 4. Receive the peer's random block (discarded).
        guard
            let peerNoise = try await connection.receive(
                minimumIncompleteLength: MWBConstants.noiseSize,
                maximumLength: MWBConstants.noiseSize),
            peerNoise.count == MWBConstants.noiseSize
        else {
            throw ChannelError.handshakeFailed("short noise block")
        }
        _ = crypto.decrypt(peerNoise)

        // 5. Receive the peer's header packet.
        guard
            let peerHeader = try await connection.receive(
                minimumIncompleteLength: MWBConstants.bigPacketSize,
                maximumLength: MWBConstants.bigPacketSize),
            peerHeader.count == MWBConstants.bigPacketSize
        else {
            throw ChannelError.handshakeFailed("short header packet")
        }
        let peer = MWBPacket(rawData: crypto.decrypt(peerHeader))

        guard peer.type == PackageType.clipboard.rawValue || peer.type == PackageType.clipboardPush.rawValue else {
            throw ChannelError.handshakeFailed("unexpected packet type \(peer.type)")
        }

        let peerName = peer.machineName
        if !remoteName.isEmpty && peerName != remoteName {
            throw ChannelError.handshakeFailed("peer \(peerName) is not \(remoteName)")
        }

        let peerPostAction = ClipboardPostAction(rawValue: peer.dataUInt32(at: 0)) ?? .other
        return PeerInfo(
            isPusher: peer.type == PackageType.clipboardPush.rawValue,
            postAction: peerPostAction)
    }

    // MARK: - Serving (Mac sends)

    /// Serves the staged data. Returns true when a final message was sent
    /// (the caller should wait for the peer's close); false when the
    /// connection should be closed immediately (nothing staged — the
    /// reference closes the socket without a header in that case).
    private func serveTransfer(_ connection: NWConnection, crypto: MWBCrypto) async throws -> Bool {
        // An in-progress drag file takes precedence (reference checks
        // Clipboard.LastDragDropFile before LastClipboardData).
        if let dragPath = pendingDragFile {
            try await serveFile(connection, crypto: crypto, path: dragPath)
            return true
        }

        guard let pending = pendingData else {
            // Nothing staged: close without a header; the peer reports its
            // own "no data available" error.
            mwbWarning(MWBLog.clipboard, "Clipboard channel: pull requested but nothing is staged")
            return false
        }

        switch pending {
        case .text(let compressed):
            mwbInfo(MWBLog.clipboard, "Clipboard channel: serving text (\(compressed.count) bytes)")
            try await sendHeader(connection, crypto: crypto, size: Int64(compressed.count), name: "text")
            try await sendBodyData(connection, crypto: crypto, body: compressed)

        case .image(let png):
            mwbInfo(MWBLog.clipboard, "Clipboard channel: serving image (\(png.count) bytes)")
            try await sendHeader(connection, crypto: crypto, size: Int64(png.count), name: "image")
            try await sendBodyData(connection, crypto: crypto, body: png)

        case .file(let url):
            try await serveFile(connection, crypto: crypto, path: url.path)

        case .directory(let path):
            try await sendHeader(
                connection, crypto: crypto, size: 0,
                name: "\(path) - Folder is not supported, zip it first!",
                isFinal: true)

        case .fileTooBig(let path):
            try await sendHeader(
                connection, crypto: crypto, size: 0,
                name: "\(path) - File too big (greater than 100MB), please drag and drop the file instead!",
                isFinal: true)
        }
        return true
    }

    /// Serves a file from disk, streaming it in chunks. Mirrors the reference
    /// `SendClipboardData` file branch, including the not-found / directory /
    /// too-big header fallbacks.
    private func serveFile(_ connection: NWConnection, crypto: MWBCrypto, path: String) async throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let fileType = attributes?[.type] as? FileAttributeType

        if fileType == .typeDirectory {
            try await sendHeader(
                connection, crypto: crypto, size: 0,
                name: "\(path) - Folder is not supported, zip it first!",
                isFinal: true)
            return
        }

        guard fileType == .typeRegular, let size = attributes?[.size] as? Int64 else {
            if path.contains("- File too big") {
                try await sendHeader(connection, crypto: crypto, size: 0, name: path, isFinal: true)
            } else {
                try await sendHeader(connection, crypto: crypto, size: 0, name: "\(path) not found!", isFinal: true)
            }
            return
        }

        mwbInfo(MWBLog.clipboard, "Clipboard channel: serving file \(path) (\(size) bytes)")
        try await sendHeader(connection, crypto: crypto, size: size, name: path)

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        // Buffer reads and emit only block-aligned writes; the final write is
        // zero-padded to a 32-byte multiple (the receiver trims to size).
        var pending = Data()
        var sent: Int64 = 0

        while true {
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty {
                // EOF before the expected size: flush what we have.
                if !pending.isEmpty {
                    try await sendPaddedFinal(connection, crypto: crypto, block: &pending)
                }
                break
            }

            pending.append(chunk)
            sent += Int64(chunk.count)

            if sent >= size {
                try await sendPaddedFinal(connection, crypto: crypto, block: &pending)
                break
            }

            let alignedLength = pending.count - pending.count % 32
            if alignedLength > 0 {
                let emit = pending.prefix(alignedLength)
                pending.removeFirst(alignedLength)
                try await connection.send(content: crypto.encrypt(emit))
            }
        }
    }

    /// Sends the final body block, zero-padded to a 32-byte multiple.
    private func sendPaddedFinal(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        block: inout Data
    ) async throws {
        let remainder = block.count % 32
        if remainder != 0 {
            block.append(Data(count: 32 - remainder))
        }
        try await connection.sendFinal(content: crypto.encrypt(block))
        block.removeAll(keepingCapacity: false)
    }

    // MARK: - Receiving (Mac receives)

    private func receiveTransfer(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        postAction: ClipboardPostAction
    ) async throws {
        guard !isTransferring else {
            mwbInfo(MWBLog.clipboard, "Clipboard channel: rejecting transfer, another one is active")
            return
        }
        isTransferring = true
        defer { isTransferring = false }

        let headerPlain = crypto.decrypt(try await receiveExactly(connection, count: Self.headerSize))
        guard let header = Self.parseHeader(headerPlain) else {
            throw ChannelError.badHeader
        }

        let (size, name) = header
        mwbInfo(MWBLog.clipboard, "Clipboard channel: receiving \(name) (\(size) bytes), postAction=\(postAction.wireName)")

        let lowercased = name.lowercased()
        if lowercased.hasPrefix("image") {
            let data = try await receiveBody(connection, crypto: crypto, size: size)
            await onReceivedImage?(data)
            mwbInfo(MWBLog.clipboard, "Clipboard channel: received image (\(data.count) bytes)")
        } else if lowercased.hasPrefix("text") {
            let data = try await receiveBody(connection, crypto: crypto, size: size)
            let decoded = ClipboardCodec.decodeTextPayload(ClipboardCodec.decompressData(data))
            await onReceivedText?(decoded)
            mwbInfo(MWBLog.clipboard, "Clipboard channel: received text")
        } else if size > 0 {
            let url = try await receiveFile(connection, crypto: crypto, size: size, name: name, postAction: postAction)
            await onReceivedFile?(url, postAction)
        } else {
            // size == 0: the peer reported an error in the header name.
            mwbWarning(MWBLog.clipboard, "Clipboard channel: remote reported: \(name)")
        }
    }

    /// Writes a received file to disk via a hidden unique `.{uuid}.partial`
    /// staging file and an atomic move (reference `ReceivedDestinationFile`),
    /// so an interrupted transfer never leaves a visible partial file and
    /// never touches the destination. The pasteboard is only handed the
    /// destination URL after the body matched the advertised size exactly.
    /// Destination depends on the post action:
    /// `.desktop` → `~/Desktop/MouseWithoutBorders/<name>`,
    /// otherwise `~/Library/Application Support/MWBClient/Received/<name>`.
    private func receiveFile(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        size: Int64,
        name: String,
        postAction: ClipboardPostAction
    ) async throws -> URL {
        let basename = Self.baseFileName(of: name)
        let folder: URL
        if postAction == .desktop {
            folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/MouseWithoutBorders", isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MWBClient/Received", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = folder.appendingPathComponent(basename)
        let stagingURL = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        // Removes the staging file when the transfer fails; a no-op after a
        // successful move.
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }

        try await receiveBody(connection, crypto: crypto, size: size) { chunk in
            try handle.write(contentsOf: chunk)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destination)
        mwbInfo(MWBLog.clipboard, "Clipboard channel: received file \(destination.path)")
        return destination
    }

    // MARK: - Transfer framing

    /// Size of the transfer header on the wire (matches the reference).
    static let headerSize = 1024

    /// How long a sender waits for the receiver's close before cancelling
    /// (reference CLOSE_TIMEOUT = 10 s).
    static let closeTimeout: TimeInterval = 10

    /// Body chunk size for sends and receives.
    static let chunkSize = 64 * 1024

    /// Encodes a transfer header: `"{size}*{name}"` in UTF-16LE, zero-padded
    /// to exactly 1024 bytes (reference `Common.GetBytesU` + 1024-byte buffer).
    static func encodeHeader(size: Int64, name: String) -> Data {
        let text = "\(size)*\(name)"
        var data = text.data(using: .utf16LittleEndian) ?? Data()
        if data.count > headerSize {
            // Even-length truncation never splits a UTF-16 surrogate pair.
            data = data.prefix(headerSize)
        } else if data.count < headerSize {
            data.append(Data(count: headerSize - data.count))
        }
        return data
    }

    /// Parses a 1024-byte transfer header back into `(size, name)`. Returns
    /// nil when the header is not in the `"{size}*{name}"` form.
    static func parseHeader(_ data: Data) -> (size: Int64, name: String)? {
        guard let text = String(data: data, encoding: .utf16LittleEndian) else { return nil }
        let trimmed = text.replacingOccurrences(of: "\0", with: "")
        guard let star = trimmed.firstIndex(of: "*") else { return nil }
        guard let size = Int64(trimmed[..<star]) else { return nil }
        let name = String(trimmed[trimmed.index(after: star)...])
        return (size, name)
    }

    /// Final path component of a sender-provided transfer-header path,
    /// mirroring .NET `Path.GetFileName`: splits on BOTH '\' and '/'. The
    /// reference sender transmits the full source path (e.g.
    /// "D:\OneDrive - Aiursoft\cg\x.png" from Windows), while
    /// NSString.lastPathComponent only splits on '/'.
    static func baseFileName(of path: String) -> String {
        guard let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last else {
            return path
        }
        return String(last)
    }

    private func sendHeader(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        size: Int64,
        name: String,
        isFinal: Bool = false
    ) async throws {
        let header = crypto.encrypt(Self.encodeHeader(size: size, name: name))
        if isFinal {
            // Header-only transfer: close the send side gracefully so the
            // header is delivered before the connection is cancelled.
            try await connection.sendFinal(content: header)
        } else {
            try await connection.send(content: header)
        }
    }

    /// Sends an in-memory body in chunks, zero-padding the final chunk to a
    /// 32-byte multiple.
    private func sendBodyData(_ connection: NWConnection, crypto: MWBCrypto, body: Data) async throws {
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = body.index(offset, offsetBy: Self.chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            var block = body.subdata(in: offset..<end)
            offset = end
            if offset == body.endIndex {
                let remainder = block.count % 32
                if remainder != 0 {
                    block.append(Data(count: 32 - remainder))
                }
                try await connection.sendFinal(content: crypto.encrypt(block))
            } else {
                try await connection.send(content: crypto.encrypt(block))
            }
        }
    }

    /// Reads exactly `count` bytes of ciphertext.
    private func receiveExactly(_ connection: NWConnection, count: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            guard
                let chunk = try await connection.receive(
                    minimumIncompleteLength: count - buffer.count,
                    maximumLength: count - buffer.count),
                !chunk.isEmpty
            else {
                throw ChannelError.shortRead(received: Int64(buffer.count), expected: Int64(count))
            }
            buffer.append(chunk)
        }
        return buffer
    }

    /// Receives a body of `size` plaintext bytes. Ciphertext is buffered and
    /// decrypted in whole 16-byte AES blocks; padding beyond `size` is
    /// discarded, matching the reference receiver's trim-to-size behavior.
    private func receiveBody(
        _ connection: NWConnection,
        crypto: MWBCrypto,
        size: Int64,
        sink: (Data) throws -> Void
    ) async throws {
        var received: Int64 = 0
        var cipherBuffer = Data()

        while received < size {
            guard
                let chunk = try await connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: Self.chunkSize),
                !chunk.isEmpty
            else {
                throw ChannelError.shortRead(received: received, expected: size)
            }

            cipherBuffer.append(chunk)
            let alignedLength = cipherBuffer.count - cipherBuffer.count % MWBConstants.ivLength
            guard alignedLength > 0 else { continue }

            let ciphertext = cipherBuffer.prefix(alignedLength)
            cipherBuffer.removeFirst(alignedLength)
            let plain = crypto.decrypt(ciphertext)

            let remaining = size - received
            let take = min(Int64(plain.count), remaining)
            try sink(plain.prefix(Int(take)))
            received += take
        }
    }

    /// Receives a body of `size` plaintext bytes into memory.
    private func receiveBody(_ connection: NWConnection, crypto: MWBCrypto, size: Int64) async throws -> Data {
        var result = Data()
        result.reserveCapacity(Int(min(size, 32 * 1024 * 1024)))
        try await receiveBody(connection, crypto: crypto, size: size) { chunk in
            result.append(chunk)
        }
        return result
    }

    // MARK: - Helpers

    private static func makeTCPOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        return options
    }

    private static func waitForReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let flag = ResumeOnce()
            connection.stateUpdateHandler = { newState in
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
                    continuation.resume(throwing: ChannelError.cancelled)
                default:
                    break
                }
            }
        }
    }
}

// MARK: - NWConnection graceful-close extension

extension NWConnection {
    /// Sends content followed by a FIN, so the data is committed to the wire
    /// before the connection is cancelled. Cancelling right after a plain
    /// `send` can discard unacknowledged data; this mirrors the reference's
    /// `Socket.Close(timeout)` linger semantics.
    func sendFinal(content: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: content,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }
}

/// Thread-safe one-shot flag for resuming a continuation exactly once from
/// racing tasks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Attempts to fire the flag. Returns true for exactly one caller.
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
