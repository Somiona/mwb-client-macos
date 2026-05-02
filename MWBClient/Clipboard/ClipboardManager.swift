import AppKit
import Foundation
import os.log

// MARK: - Clipboard Manager

actor ClipboardManager {

    // MARK: Public State

    private(set) var isConnected = false
    var machineID: MachineID = .none

    // MARK: Configuration

    /// Whether to sync text clipboard content.
    private var syncText: Bool

    /// Whether to sync image clipboard content.
    private var syncImages: Bool

    /// Whether to sync file clipboard content.
    private var syncFiles: Bool

    // MARK: Callbacks

    private var sendPacket: (@Sendable (MWBPacket) async -> Void)?

    func setSendPacketCallback(_ callback: @escaping @Sendable (MWBPacket) async -> Void) {
        self.sendPacket = callback
    }

    // MARK: Polling State

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

    // MARK: File Transfer State
    private(set) var pendingFileSenderID: MachineID?
    private(set) var isFileReady: Bool = false

    // MARK: Init

    init(
        machineID: MachineID,
        syncText: Bool = true,
        syncImages: Bool = true,
        syncFiles: Bool = true
    ) {
        self.machineID = machineID
        self.syncText = syncText
        self.syncImages = syncImages
        self.syncFiles = syncFiles
    }

    // MARK: Start / Stop

    func start() {
        guard !isConnected else { return }
        isConnected = true
        mwbInfo(MWBLog.clipboard, "ClipboardManager starting pasteboard polling")
        startPollLoop()
    }

    func stop() {
        mwbInfo(MWBLog.clipboard, "ClipboardManager stopping")
        pollTask?.cancel()
        pollTask = nil
        isConnected = false
        inboundPackets.removeAll()
        inboundContentType = nil
    }

    // MARK: Settings Updates

    func updateSyncSettings(syncText: Bool? = nil, syncImages: Bool? = nil, syncFiles: Bool? = nil) {
        if let syncText { self.syncText = syncText }
        if let syncImages { self.syncImages = syncImages }
        if let syncFiles { self.syncFiles = syncFiles }
    }

    func updateMachineID(_ newID: MachineID) {
        self.machineID = newID
    }

    // MARK: Receive Packets

    func handleIncomingPacket(_ packet: MWBPacket) {
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
            pendingFileSenderID = packet.src
            isFileReady = true
            mwbInfo(MWBLog.clipboard, "Received Type 69 Clipboard Notification from \(packet.src.rawValue). Ready to pull large data.")

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
                mwbInfo(MWBLog.clipboard, "Received text clipboard (\(text.count) chars)")
                writeTextToPasteboard(text)
            } else {
                mwbError(MWBLog.clipboard, "Failed to decode text clipboard from \(self.inboundPackets.count) packets")
            }

        case .clipboardImage:
            guard syncImages else { return }
            if let imageData = ClipboardCodec.decodeImage(from: inboundPackets) {
                mwbInfo(MWBLog.clipboard, "Received image clipboard (\(imageData.count) bytes)")
                writeImageToPasteboard(imageData)
            } else {
                mwbError(MWBLog.clipboard, "Failed to decode image clipboard from \(self.inboundPackets.count) packets")
            }

        default:
            break
        }
    }

    // MARK: Large File Pull

    func pullLargeData() async {
        guard let senderID = pendingFileSenderID else { return }
        mwbInfo(MWBLog.clipboard, "Initiating large data pull from machine \(senderID.rawValue)")
        
        // Mark as processing
        isFileReady = false
        pendingFileSenderID = nil
        
        guard isConnected, let sendPacket else { return }
        
        var packet = MWBPacket()
        packet.type = PackageType.clipboardAsk.rawValue
        packet.src = machineID
        packet.des = senderID
        // PostAction would be set here if needed (e.g. paste file)
        
        await sendPacket(packet)
        
        // TODO: Implement secondary TCP socket on inputPort + 1
        // 1. Connect Network framework to inputPort + 1
        // 2. Exchange noise
        // 3. Receive raw file bytes
    }

    // MARK: Write to Pasteboard

    private func writeTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if success {
            lastWriteChangeCount = pasteboard.changeCount
        } else {
            mwbError(MWBLog.clipboard, "Failed to write text to pasteboard")
        }
    }

    private func writeImageToPasteboard(_ data: Data) {
        guard let image = NSImage(data: data) else {
            mwbError(MWBLog.clipboard, "Failed to create NSImage from clipboard data")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([image])
        if success {
            lastWriteChangeCount = pasteboard.changeCount
        } else {
            mwbError(MWBLog.clipboard, "Failed to write image to pasteboard")
        }
    }

    // MARK: Outbound Poll Loop

    private func startPollLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollPasteboard()
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

            await checkAndSendClipboard()
        }
    }

    private let maxClipboardDataSize = 1 * 1024 * 1024 // 1 MB (matches PowerToys inline threshold)

    private func checkAndSendClipboard() async {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // Skip if no change, or if this is a change we ourselves wrote (feedback loop)
        guard currentCount != lastSentChangeCount else { return }
        guard currentCount > lastWriteChangeCount else { return }

        // Priority: text > image > files
        if syncText, let text = readTextFromPasteboard() {
            if text.utf16.count > maxClipboardDataSize {
                mwbWarning(MWBLog.clipboard, "Text clipboard too large (\(text.utf16.count) bytes), skipping")
                lastSentChangeCount = currentCount
                return
            }
            mwbInfo(MWBLog.clipboard, "Sending text clipboard (\(text.count) chars)")
            await sendTextClipboard(text)
            lastSentChangeCount = currentCount
            return
        }

        if syncImages, let imageData = readImageFromPasteboard() {
            if imageData.count > maxClipboardDataSize {
                mwbWarning(MWBLog.clipboard, "Image clipboard too large (\(imageData.count) bytes), skipping")
                lastSentChangeCount = currentCount
                return
            }
            mwbInfo(MWBLog.clipboard, "Sending image clipboard (\(imageData.count) bytes)")
            await sendImageClipboard(imageData)
            lastSentChangeCount = currentCount
            return
        }

        if syncFiles {
            // File clipboard sync via dedicated TCP path is a future enhancement.
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
            mwbError(MWBLog.clipboard, "Failed to get TIFF representation from pasteboard image")
            return nil
        }

        guard let bitmap = NSBitmapImageRep(data: tiffData) else {
            mwbError(MWBLog.clipboard, "Failed to create NSBitmapImageRep from TIFF data")
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Send Clipboard

    private func sendTextClipboard(_ text: String) async {
        guard isConnected, let sendPacket else { return }

        let packets = ClipboardCodec.encodeText(text)
        mwbDebug(MWBLog.clipboard, "Sending text clipboard in \(packets.count) packets")
        for packet in packets {
            var mutablePacket = packet
            mutablePacket.src = machineID
            mutablePacket.des = MWBConstants.broadcastDestination
            await sendPacket(mutablePacket)
        }
    }

    private func sendImageClipboard(_ data: Data) async {
        guard isConnected, let sendPacket else { return }

        let packets = ClipboardCodec.encodeImage(data)
        mwbDebug(MWBLog.clipboard, "Sending image clipboard in \(packets.count) packets")
        for packet in packets {
            var mutablePacket = packet
            mutablePacket.src = machineID
            mutablePacket.des = MWBConstants.broadcastDestination
            await sendPacket(mutablePacket)
        }
    }
}
