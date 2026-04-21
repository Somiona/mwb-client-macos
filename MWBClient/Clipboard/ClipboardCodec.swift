import Foundation
import Compression
import os.log

/// Encodes and decodes clipboard data (text and images) into MWB protocol packets.
///
/// Matches the PowerToys MWB protocol exactly:
/// - Each chunk uses the full 48-byte data field for payload (no sequence number overhead)
/// - Ordering is guaranteed by TCP stream delivery (no per-chunk sequence numbers)
/// - Text is Deflate-compressed before chunking (matching PowerToys behavior)
/// - ClipboardDataEnd (type 76) signals end of stream with no extra payload
enum ClipboardCodec {

    // MARK: - Encode Text

    /// Encodes a string into a sequence of MWB clipboard packets.
    ///
    /// The string is converted to UTF-16 LE bytes (matching PowerToys Encoding.Unicode),
    /// then Deflate-compressed, then split into 48-byte chunks wrapped in
    /// ClipboardText (124) packets. A final ClipboardDataEnd (76) packet
    /// signals the end of the stream.
    static func encodeText(_ string: String) -> [MWBPacket] {
        let utf16Data = string.data(using: .utf16LittleEndian) ?? Data()
        let compressed = compressData(utf16Data)
        return encodeRawChunks(compressed, packetType: .clipboardText)
    }

    // MARK: - Decode Text

    /// Decodes text from a sequence of MWB clipboard packets.
    ///
    /// Extracts ClipboardText (124) data chunks, reassembles them,
    /// decompresses, and decodes from UTF-16 LE back to a String.
    static func decodeText(from packets: [MWBPacket]) -> String? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardText)
        guard !chunks.isEmpty else {
            Logger.clipboard.warning("ClipboardCodec: no text chunks found in \(packets.count) packets")
            return nil
        }
        let assembled = reassemble(chunks: chunks)
        guard !assembled.isEmpty else { return nil }
        let decompressed = decompressData(assembled)
        guard let text = String(data: decompressed, encoding: .utf16LittleEndian) else {
            Logger.clipboard.error("ClipboardCodec: failed to decode UTF-16 LE text (\(decompressed.count) bytes)")
            return nil
        }
        return text
    }

    // MARK: - Encode Image

    /// Encodes raw image data into a sequence of MWB clipboard packets.
    ///
    /// The raw bytes are split into 48-byte chunks wrapped in
    /// ClipboardImage (125) packets. A final ClipboardDataEnd (76) packet
    /// signals the end of the stream. Images are sent uncompressed
    /// (matching PowerToys behavior).
    static func encodeImage(_ data: Data) -> [MWBPacket] {
        encodeRawChunks(data, packetType: .clipboardImage)
    }

    // MARK: - Decode Image

    /// Decodes image data from a sequence of MWB clipboard packets.
    ///
    /// Extracts ClipboardImage (125) data chunks and reassembles them
    /// into the original raw image data.
    static func decodeImage(from packets: [MWBPacket]) -> Data? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardImage)
        guard !chunks.isEmpty else {
            Logger.clipboard.warning("ClipboardCodec: no image chunks found in \(packets.count) packets")
            return nil
        }
        let assembled = reassemble(chunks: chunks)
        guard !assembled.isEmpty else { return nil }
        return assembled
    }

    // MARK: - Internal

    /// Splits raw data into 48-byte chunks and creates packets of the given type.
    /// Appends a ClipboardDataEnd packet after all chunks.
    private static func encodeRawChunks(_ data: Data, packetType: PackageType) -> [MWBPacket] {
        let payloadSize = MWBConstants.dataFieldSize // 48
        var packets: [MWBPacket] = []

        if data.isEmpty {
            var packet = MWBPacket()
            packet.packageType = packetType
            packet.des = MWBConstants.broadcastDestination
            packets.append(packet)
        } else {
            var offset = 0
            while offset < data.count {
                let end = min(offset + payloadSize, data.count)
                let chunk = data[offset..<end]

                var packet = MWBPacket()
                packet.packageType = packetType
                packet.des = MWBConstants.broadcastDestination

                var dataField = Data(count: payloadSize)
                dataField.replaceSubrange(0..<chunk.count, with: chunk)
                packet.data = dataField

                packets.append(packet)
                offset = end
            }
        }

        // ClipboardDataEnd (type 76): receiver sees this and stops reading.
        var endPacket = MWBPacket()
        endPacket.packageType = .clipboardDataEnd
        endPacket.des = MWBConstants.broadcastDestination
        packets.append(endPacket)

        return packets
    }

    /// Extracts data payloads from packets matching the expected type.
    /// Skips ClipboardDataEnd and any other non-matching types.
    private static func extractChunks(from packets: [MWBPacket], expectedType: PackageType) -> [Data] {
        var chunks: [Data] = []
        for packet in packets {
            guard let ptype = packet.packageType else { continue }
            guard ptype == expectedType else { continue }
            chunks.append(packet.data)
        }
        return chunks
    }

    /// Concatenates chunk data payloads into a single buffer.
    private static func reassemble(chunks: [Data]) -> Data {
        var result = Data()
        for chunk in chunks {
            result.append(chunk)
        }
        return result
    }

    // MARK: - Compression (raw Deflate via Apple Compression, matching .NET DeflateStream)

    /// Compresses data using raw Deflate (RFC 1951), matching .NET DeflateStream.
    /// Apple's COMPRESSION_ZLIB produces raw Deflate output (RFC 1951) per Apple docs.
    private static func compressData(_ data: Data) -> Data {
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
                Logger.clipboard.error("ClipboardCodec: compression failed for \(data.count) bytes input")
                return Data()
            }
            return Data(bytes: outputBuffer, count: result)
        }
    }

    /// Decompresses raw Deflate data (RFC 1951), matching .NET DeflateStream.
    private static func decompressData(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        let outputSize = max(data.count * 4, 65_536)
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputSize)
        defer { outputBuffer.deallocate() }

        return data.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            let result = compression_decode_buffer(
                outputBuffer, outputSize,
                inputBase, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard result > 0 else {
                Logger.clipboard.error("ClipboardCodec: decompression failed for \(data.count) bytes input")
                return Data()
            }
            return Data(bytes: outputBuffer, count: result)
        }
    }
}
