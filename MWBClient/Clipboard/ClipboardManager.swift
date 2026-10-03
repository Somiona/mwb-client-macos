import AppKit
import Foundation
import os.log

// MARK: - Clipboard Manager

/// Polls the local pasteboard, sends clipboard content to the remote machine
/// (inline for payloads ≤ 1 MB, staged + beat for larger ones and files), and
/// processes inbound inline clipboard streams.
actor ClipboardManager {

    // MARK: Public State

    private(set) var isConnected = false
    var machineID: MachineID = .none
    var machineName: String = ""

    // MARK: Configuration

    /// Whether to sync text clipboard content.
    private var syncText: Bool

    /// Whether to sync image clipboard content.
    private var syncImages: Bool

    /// Whether to sync file clipboard content.
    private var syncFiles: Bool

    /// Threshold above which data is staged and served over the clipboard
    /// channel instead of inline (PowerToys
    /// MAX_CLIPBOARD_DATA_SIZE_CAN_BE_SENT_INSTANTLY_TCP = 1 MB).
    private let maxClipboardDataSize = 1 * 1024 * 1024

    /// Largest file that can be staged (PowerToys
    /// MAX_CLIPBOARD_FILE_SIZE_CAN_BE_SENT = 100 MB).
    private let maxClipboardFileSize = 100 * 1024 * 1024

    /// How long a clipboard beat stays eligible for a pull (PowerToys
    /// BIG_CLIPBOARD_DATA_TIMEOUT = 30 s).
    static let bigClipboardDataTimeout: TimeInterval = 30.0

    // MARK: Clipboard channel

    /// Large-data/file channel; staged payloads are served from it.
    private var channel: ClipboardChannel?

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

    // MARK: Beat State

    /// The last received clipboard beat (type 69): which machine has large
    /// data and when it was announced. Consumed by the coordinator when this
    /// machine gains control, mirroring the reference pull trigger.
    private var lastBeat: (src: MachineID, time: Date)?

    // MARK: Init

    init(
        machineID: MachineID,
        machineName: String = "",
        syncText: Bool = true,
        syncImages: Bool = true,
        syncFiles: Bool = true
    ) {
        self.machineID = machineID
        self.machineName = machineName
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
        lastBeat = nil
    }

    // MARK: Settings Updates

    func updateSyncSettings(syncText: Bool? = nil, syncImages: Bool? = nil, syncFiles: Bool? = nil) {
        if let syncText { self.syncText = syncText }
        if let syncImages { self.syncImages = syncImages }
        if let syncFiles { self.syncFiles = syncFiles }
    }

    func updateIdentity(machineID: MachineID, machineName: String) {
        self.machineID = machineID
        self.machineName = machineName
    }

    // MARK: Clipboard channel wiring

    func setClipboardChannel(_ channel: ClipboardChannel?) {
        self.channel = channel
    }

    /// Returns and clears the recorded clipboard beat if it is still fresh
    /// (< ``bigClipboardDataTimeout``); the caller should pull the remote
    /// machine's large clipboard data when this returns true.
    func consumeFreshBeat() -> Bool {
        guard let beat = lastBeat else { return false }
        lastBeat = nil
        let isFresh = Date().timeIntervalSince(beat.time) < Self.bigClipboardDataTimeout
        if isFresh {
            mwbInfo(MWBLog.clipboard, "Fresh clipboard beat from machine \(beat.src.rawValue); pulling")
        }
        return isFresh
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
            // The inline transfer already delivered the content; a pending
            // beat is no longer needed (mirrors the reference receiver).
            lastBeat = nil

        case .clipboard:
            // Type 69 beat: the sender has large data (> 1 MB) or a file.
            lastBeat = (src: packet.src, time: Date())
            mwbInfo(MWBLog.clipboard, "Received clipboard beat from machine \(packet.src.rawValue)")

        case .clipboardAsk:
            // Type 78: the remote asks us to push our staged data (it could
            // not connect to our clipboard port directly).
            guard packet.des == machineID else { return }
            let postAction = ClipboardPostAction(rawValue: packet.dataUInt32(at: 0)) ?? .other
            mwbInfo(MWBLog.clipboard, "Received ClipboardAsk from machine \(packet.src.rawValue) (postAction=\(postAction.wireName)); pushing staged data")
            let channel = self.channel
            Task {
                await channel?.pushPendingData(postAction: postAction)
            }

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
            if let decoded = ClipboardCodec.decodeText(from: inboundPackets) {
                mwbInfo(MWBLog.clipboard, "Received text clipboard (\(decoded.plain?.count ?? 0) chars)")
                writeTextToPasteboard(decoded)
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

    // MARK: Write to Pasteboard

    private func writeTextToPasteboard(_ decoded: ClipboardCodec.DecodedClipboardText) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var success = false
        if let plain = decoded.plain {
            success = pasteboard.setString(plain, forType: .string) || success
        }
        if let rtf = decoded.rtf?.data(using: .utf8) {
            success = pasteboard.setData(rtf, forType: .rtf) || success
        }
        if let html = decoded.html?.data(using: .utf8) {
            success = pasteboard.setData(html, forType: .html) || success
        }

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

    /// Writes a received file URL to the pasteboard as a file drop list
    /// (reference sets a FileDropList with the received path).
    func writeFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([url as NSURL])
        if success {
            lastWriteChangeCount = pasteboard.changeCount
        } else {
            mwbError(MWBLog.clipboard, "Failed to write file URL to pasteboard")
        }
    }

    // MARK: Channel-delivered content

    /// Writes text received over the clipboard channel to the pasteboard.
    func handleChannelText(_ decoded: ClipboardCodec.DecodedClipboardText) {
        guard syncText else { return }
        mwbInfo(MWBLog.clipboard, "Received channel text (\(decoded.plain?.count ?? 0) chars)")
        writeTextToPasteboard(decoded)
    }

    /// Writes an image received over the clipboard channel to the pasteboard.
    func handleChannelImage(_ data: Data) {
        guard syncImages else { return }
        mwbInfo(MWBLog.clipboard, "Received channel image (\(data.count) bytes)")
        writeImageToPasteboard(data)
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

    private func checkAndSendClipboard() async {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        // Skip if no change, or if this is a change we ourselves wrote (feedback loop)
        guard currentCount != lastSentChangeCount else { return }
        guard currentCount > lastWriteChangeCount else { return }

        // Priority: text > image > files. A pasteboard holding file URLs is
        // always a file copy (Finder ⌘C also puts the filename as a string
        // flavor and the file icon as TIFF, which must not win over the file
        // itself).
        if syncText, let contents = Self.readText(from: pasteboard) {
            let payload = ClipboardCodec.makeTextPayload(
                text: contents.text, rtf: contents.rtf, html: contents.html)
            let compressed = ClipboardCodec.compressData(
                payload.data(using: .utf16LittleEndian) ?? Data())

            if compressed.count > maxClipboardDataSize {
                mwbInfo(MWBLog.clipboard, "Staging large text clipboard (\(compressed.count) bytes), sending beat")
                await channel?.setPendingData(.text(compressed))
                await sendClipboardBeat()
            } else {
                mwbInfo(MWBLog.clipboard, "Sending text clipboard (\(contents.text.count) chars)")
                await sendTextClipboard(text: contents.text, rtf: contents.rtf, html: contents.html, compressed: compressed)
            }
            lastSentChangeCount = currentCount
            return
        }

        if syncImages, let imageData = Self.readImage(from: pasteboard) {
            if imageData.count > maxClipboardDataSize {
                mwbInfo(MWBLog.clipboard, "Staging large image clipboard (\(imageData.count) bytes), sending beat")
                await channel?.setPendingData(.image(imageData))
                await sendClipboardBeat()
            } else {
                mwbInfo(MWBLog.clipboard, "Sending image clipboard (\(imageData.count) bytes)")
                await sendImageClipboard(imageData)
            }
            lastSentChangeCount = currentCount
            return
        }

        if syncFiles, let urls = Self.readFiles(from: pasteboard) {
            let url = urls[0]
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            guard exists else {
                mwbWarning(MWBLog.clipboard, "Clipboard file not found: \(url.path)")
                return
            }

            if isDirectory.boolValue {
                await channel?.setPendingData(.directory(url.path))
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                if size > maxClipboardFileSize {
                    await channel?.setPendingData(.fileTooBig(url.path))
                } else {
                    await channel?.setPendingData(.file(url))
                }
            }

            // The protocol has no inline file path; files always use the beat.
            mwbInfo(MWBLog.clipboard, "Staging file clipboard \(url.path), sending beat")
            await sendClipboardBeat()
            lastSentChangeCount = currentCount
            return
        }
    }

    // MARK: Read from Pasteboard

    /// Returns the pasteboard's text content, or nil. A Finder file copy
    /// exposes the filename as a string flavor alongside the file URL — the
    /// reference never treats a FileDropList as text, so a file URL here must
    /// fall through to the file branch. Static + parameterized for
    /// isolated-pasteboard testing.
    static func readText(from pasteboard: NSPasteboard) -> (text: String, rtf: String?, html: String?)? {
        guard pasteboard.types?.contains(.fileURL) != true else { return nil }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }
        let rtf = pasteboard.data(forType: .rtf).flatMap { String(data: $0, encoding: .utf8) }
        let html = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        return (text, rtf, html)
    }

    /// Returns PNG data for image content on the pasteboard, or nil.
    /// A real Finder file copy (⌘C in Finder) also exposes the file's TIFF
    /// icon, which NSImage(pasteboard:) would load — the reference never
    /// treats a FileDropList as CF_BITMAP, so Finder-shaped copies must fall
    /// through to the file branch. Copies from other sources (screenshot
    /// tools, "copy as image" utilities) expose a bare file URL without the
    /// Finder markers; those resolve here as images, matching how macOS apps
    /// paste them. Static + parameterized for isolated-pasteboard testing.
    static func readImage(from pasteboard: NSPasteboard) -> Data? {
        guard !Self.isFinderFileCopy(pasteboard) else { return nil }
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

    /// True when the pasteboard carries a Finder ⌘C file copy. Finder marks
    /// its copies with private flavors (verified against a live Finder copy:
    /// "com.apple.finder.noderef", "fndf"); programmatic writers of bare
    /// file URLs (screenshot apps, copy-as-image utilities) do not.
    static func isFinderFileCopy(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.types?.contains(.fileURL) == true else { return false }
        let finderMarkers: Set<String> = [
            "com.apple.finder.noderef",
            "com.apple.finder.node",
            "fndf",
        ]
        return pasteboard.types?.contains { finderMarkers.contains($0.rawValue) } == true
    }

    /// Returns the file URLs on the pasteboard (FileDropList equivalent),
    /// or nil when the pasteboard holds no file URLs. Static +
    /// parameterized for isolated-pasteboard testing.
    static func readFiles(from pasteboard: NSPasteboard) -> [URL]? {
        guard pasteboard.types?.contains(.fileURL) == true else { return nil }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return nil
        }
        return urls
    }

    // MARK: Send Clipboard

    /// Broadcasts a type 69 clipboard beat, announcing that this machine has
    /// large data available on the clipboard channel.
    private func sendClipboardBeat() async {
        guard isConnected, let sendPacket else { return }

        var packet = MWBPacket()
        packet.type = PackageType.clipboard.rawValue
        packet.src = machineID
        packet.des = MWBConstants.broadcastDestination
        packet.machineName = machineName

        await sendPacket(packet)
    }

    private func sendTextClipboard(
        text: String,
        rtf: String?,
        html: String?,
        compressed: Data
    ) async {
        guard isConnected, let sendPacket else { return }

        // Keep the staged copy in sync so a later pull can serve the same data.
        await channel?.setPendingData(.text(compressed))

        let packets = ClipboardCodec.encodeText(text, rtf: rtf, html: html)
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

        // Keep the staged copy in sync so a later pull can serve the same data.
        await channel?.setPendingData(.image(data))

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
