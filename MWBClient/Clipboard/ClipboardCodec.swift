import Compression
import Foundation
import os.log

/// Encodes and decodes clipboard data (text and images) into MWB protocol packets.
///
/// Matches the PowerToys MWB protocol exactly:
/// - Each chunk uses the full 48-byte data field for payload (no sequence number overhead)
/// - Ordering is guaranteed by TCP stream delivery (no per-chunk sequence numbers)
/// - Text is Deflate-compressed before chunking (matching PowerToys behavior)
/// - Text payloads use the PowerToys "TXT"/"RTF"/"HTM" segment format
/// - ClipboardDataEnd (type 76) signals end of stream with no extra payload
enum ClipboardCodec {

    // MARK: - Text segment format

    /// Segment separator of the PowerToys text clipboard format
    /// (Clipboard.TEXT_TYPE_SEP).
    static let textTypeSeparator = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}"

    /// A decoded PowerToys text clipboard payload. Any subset of the segments
    /// may be present; senders only include non-empty ones.
    struct DecodedClipboardText: Equatable {
        var plain: String?
        var rtf: String?
        var html: String?
    }

    /// Builds the PowerToys text clipboard payload:
    /// `"TXT" + text + SEP` plus optional `"RTF" + rtf + SEP` and
    /// `"HTM" + html + SEP` segments.
    static func makeTextPayload(text: String, rtf: String? = nil, html: String? = nil) -> String {
        var payload = "TXT" + text + textTypeSeparator
        if let rtf, !rtf.isEmpty {
            payload += "RTF" + rtf + textTypeSeparator
        }
        if let html, !html.isEmpty {
            payload += "HTM" + html + textTypeSeparator
        }
        return payload
    }

    /// Decodes a decompressed UTF-16LE text payload into its TXT/RTF/HTM
    /// segments. Payloads without the separator are treated as plain text
    /// (legacy senders); the reference receiver behaves the same way.
    static func decodeTextPayload(_ data: Data) -> DecodedClipboardText {
        guard let st = String(data: data, encoding: .utf16LittleEndian) else {
            return DecodedClipboardText(plain: nil, rtf: nil, html: nil)
        }
        return decodeTextPayload(st)
    }

    /// Overload operating on an already-decoded UTF-16 string.
    static func decodeTextPayload(_ st: String) -> DecodedClipboardText {
        guard st.contains(textTypeSeparator) else {
            return DecodedClipboardText(plain: st, rtf: nil, html: nil)
        }

        var decoded = DecodedClipboardText(plain: nil, rtf: nil, html: nil)
        var segmentIndex = 0

        for segment in st.components(separatedBy: textTypeSeparator) {
            guard !segment.isEmpty else { continue }
            defer { segmentIndex += 1 }

            if segment.count >= 3 {
                let tag = segment.prefix(3)
                let payload = String(segment.dropFirst(3))
                switch tag {
                case "TXT":
                    decoded.plain = payload
                    continue
                case "RTF":
                    decoded.rtf = payload
                    continue
                case "HTM":
                    decoded.html = payload
                    continue
                default:
                    break
                }
            }

            // Unframed segment: the reference receiver only accepts it as the
            // plain text when it is the first segment.
            if segmentIndex == 0 {
                decoded.plain = segment
            }
        }

        return decoded
    }

    // MARK: - Encode Text

    /// Encodes a string into a sequence of MWB clipboard packets.
    ///
    /// The payload is built via ``makeTextPayload``, converted to UTF-16 LE
    /// bytes (matching PowerToys Encoding.Unicode), then Deflate-compressed,
    /// then split into 48-byte chunks wrapped in ClipboardText (124) packets.
    /// A final ClipboardDataEnd (76) packet signals the end of the stream.
    static func encodeText(_ string: String, rtf: String? = nil, html: String? = nil) -> [MWBPacket] {
        let payload = makeTextPayload(text: string, rtf: rtf, html: html)
        let utf16Data = payload.data(using: .utf16LittleEndian) ?? Data()
        let compressed = compressData(utf16Data)
        return encodeRawChunks(compressed, packetType: .clipboardText)
    }

    // MARK: - Decode Text

    /// Decodes text from a sequence of MWB clipboard packets.
    ///
    /// Extracts ClipboardText (124) data chunks, reassembles them,
    /// decompresses, decodes from UTF-16 LE, and parses the TXT/RTF/HTM
    /// segments.
    static func decodeText(from packets: [MWBPacket]) -> DecodedClipboardText? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardText)
        guard !chunks.isEmpty else {
            mwbWarning(MWBLog.clipboard, "ClipboardCodec: no text chunks found in \(packets.count) packets")
            return nil
        }
        let assembled = reassemble(chunks: chunks)
        guard !assembled.isEmpty else { return nil }
        let decompressed = decompressData(assembled)
        return decodeTextPayload(decompressed)
    }

    // MARK: - Encode Image

    /// Encodes raw image data into a sequence of MWB clipboard packets.
    ///
    /// The raw bytes are split into 48-byte chunks wrapped in
    /// ClipboardImage (125) packets. A final ClipboardDataEnd (76) packet
    /// signals the end of the stream. Images are PNG on the wire and sent
    /// uncompressed (matching PowerToys behavior).
    static func encodeImage(_ data: Data) -> [MWBPacket] {
        encodeRawChunks(data, packetType: .clipboardImage)
    }

    // MARK: - Decode Image

    /// Decodes image data from a sequence of MWB clipboard packets.
    ///
    /// Extracts ClipboardImage (125) data chunks and reassembles them
    /// into the original raw image data (PNG on the wire).
    static func decodeImage(from packets: [MWBPacket]) -> Data? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardImage)
        guard !chunks.isEmpty else { return nil }
        let assembled = reassemble(chunks: chunks)
        return assembled.isEmpty ? nil : assembled
    }

    // MARK: - Internal

    /// Splits raw data into 48-byte chunks and creates packets of the given type.
    /// Appends a ClipboardDataEnd packet after all chunks.
    private static func encodeRawChunks(_ data: Data, packetType: PackageType) -> [MWBPacket] {
        var packets: [MWBPacket] = []
        var offset = data.startIndex

        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: MWBConstants.dataFieldSize, limitedBy: data.endIndex) ?? data.endIndex
            var packet = MWBPacket()
            packet.type = packetType.rawValue
            packet.data = data.subdata(in: offset..<end)
            packets.append(packet)
            offset = end
        }

        var end = MWBPacket()
        end.type = PackageType.clipboardDataEnd.rawValue
        packets.append(end)
        return packets
    }

    /// Extracts data payloads from packets matching the expected type.
    /// Skips ClipboardDataEnd and any other non-matching types.
    private static func extractChunks(from packets: [MWBPacket], expectedType: PackageType) -> [Data] {
        packets.compactMap { packet in
            guard packet.packageType == expectedType else { return nil }
            return packet.data
        }
    }

    /// Concatenates chunk data payloads into a single buffer.
    private static func reassemble(chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    // MARK: - Compression (raw Deflate via Apple Compression, matching .NET DeflateStream)

    /// Compresses data using raw Deflate (RFC 1951), matching .NET DeflateStream.
    /// Apple's COMPRESSION_ZLIB produces raw Deflate output (RFC 1951) per Apple docs.
    static func compressData(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        let outputSize = max(data.count * 2, 4096)
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputSize)
        defer { outputBuffer.deallocate() }

        return data.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            let result = compression_encode_buffer(
                outputBuffer, outputSize,
                inputBase, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard result > 0 else {
                mwbError(MWBLog.clipboard, "ClipboardCodec: compression failed for \(data.count) bytes input")
                return Data()
            }
            return Data(bytes: outputBuffer, count: result)
        }
    }

    /// Decompresses raw Deflate data (RFC 1951), matching .NET DeflateStream.
    ///
    /// Deflate self-terminates; trailing zero padding (from zero-padded
    /// 48-byte chunks) is ignored, matching the reference receiver. The
    /// output buffer starts small and doubles until the payload fits, since
    /// highly compressible data can expand far beyond 4x.
    static func decompressData(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var capacity = max(data.count * 4, 65_536)
        while true {
            let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { outputBuffer.deallocate() }

            let result = data.withUnsafeBytes { inputPtr in
                guard let inputBase = inputPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBuffer, capacity,
                    inputBase, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if result > 0 {
                return Data(bytes: outputBuffer, count: result)
            }
            if capacity >= 512 * 1024 * 1024 {
                mwbError(MWBLog.clipboard, "ClipboardCodec: decompression failed for \(data.count) bytes input")
                return Data()
            }
            capacity *= 2
        }
    }
}
