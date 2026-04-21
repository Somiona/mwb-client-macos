import Foundation

/// Encodes and decodes clipboard data (text and images) into MWB protocol packets.
///
/// Text is UTF-8 encoded and sent as type 124 (ClipboardText) chunks,
/// terminated by type 76 (ClipboardDataEnd).
/// Images are sent as type 125 (ClipboardImage) chunks,
/// terminated by type 76 (ClipboardDataEnd).
///
/// Each chunk uses the first 4 bytes of the 48-byte data field as a
/// little-endian sequence number, leaving 44 bytes for payload.
enum ClipboardCodec {

    // MARK: - Layout

    /// Number of bytes reserved for the sequence number at the start of each chunk.
    static let sequenceSize = 4

    /// Usable payload bytes per chunk (48 - 4 for sequence number).
    static let chunkPayloadSize = MWBConstants.dataFieldSize - sequenceSize

    // MARK: - Encode Text

    /// Encodes a string into a sequence of MWB packets.
    ///
    /// The string is UTF-8 encoded, split into chunks, and wrapped in
    /// ClipboardText (124) packets. A final ClipboardDataEnd (76) packet
    /// signals the end of the stream.
    ///
    /// - Parameter string: The text to encode.
    /// - Returns: An array of packets ready for transmission.
    static func encodeText(_ string: String) -> [MWBPacket] {
        let utf8Data = Data(string.utf8)
        return encodeRawChunks(utf8Data, packetType: .clipboardText)
    }

    // MARK: - Decode Text

    /// Decodes text from a sequence of MWB clipboard packets.
    ///
    /// Accepts ClipboardText (124) packets, reassembles chunks in sequence
    /// order, and returns the decoded UTF-8 string.
    ///
    /// - Parameter packets: The received clipboard packets (may include the
    ///   trailing ClipboardDataEnd packet; it is ignored for text content).
    /// - Returns: The decoded string, or `nil` if the packets are invalid or
    ///   contain no text data.
    static func decodeText(from packets: [MWBPacket]) -> String? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardText)
        guard !chunks.isEmpty else { return nil }
        let totalBytes = extractTotalBytes(from: packets) ?? chunks.count * chunkPayloadSize
        let assembled = reassemble(chunks: chunks, totalBytes: totalBytes)
        guard !assembled.isEmpty else { return nil }
        return String(data: assembled, encoding: .utf8)
    }

    // MARK: - Encode Image

    /// Encodes PNG image data into a sequence of MWB packets.
    ///
    /// The raw PNG bytes are split into chunks and wrapped in
    /// ClipboardImage (125) packets. A final ClipboardDataEnd (76) packet
    /// signals the end of the stream.
    ///
    /// - Parameter data: The PNG image data to encode.
    /// - Returns: An array of packets ready for transmission.
    static func encodeImage(_ data: Data) -> [MWBPacket] {
        encodeRawChunks(data, packetType: .clipboardImage)
    }

    // MARK: - Decode Image

    /// Decodes image data from a sequence of MWB clipboard packets.
    ///
    /// Accepts ClipboardImage (125) packets, reassembles chunks in sequence
    /// order, and returns the raw PNG data.
    ///
    /// - Parameter packets: The received clipboard packets (may include the
    ///   trailing ClipboardDataEnd packet; it is ignored for image content).
    /// - Returns: The reassembled PNG data, or `nil` if the packets are
    ///   invalid or contain no image data.
    static func decodeImage(from packets: [MWBPacket]) -> Data? {
        let chunks = extractChunks(from: packets, expectedType: .clipboardImage)
        guard !chunks.isEmpty else { return nil }
        let totalBytes = extractTotalBytes(from: packets) ?? chunks.count * chunkPayloadSize
        let assembled = reassemble(chunks: chunks, totalBytes: totalBytes)
        guard !assembled.isEmpty else { return nil }
        return assembled
    }

    // MARK: - Internal

    /// A parsed chunk with its sequence number and payload bytes.
    private struct Chunk {
        let sequence: UInt32
        let payload: Data
    }

    /// Generic chunking logic shared by text and image encoding.
    private static func encodeRawChunks(_ data: Data, packetType: PackageType) -> [MWBPacket] {
        let payloadSize = chunkPayloadSize
        let totalChunks = data.isEmpty ? 1 : (data.count + payloadSize - 1) / payloadSize
        var packets: [MWBPacket] = []

        for seq in 0..<totalChunks {
            let start = seq * payloadSize
            let end = min(start + payloadSize, data.count)
            let payloadSlice = data[start..<end]

            var packet = MWBPacket()
            packet.packageType = packetType
            packet.setDataUInt32(UInt32(seq), at: 0)

            // Write payload starting at offset 4 (after sequence number)
            var dataBytes = Data(count: MWBConstants.dataFieldSize)
            dataBytes.replaceSubrange(sequenceSize..<(sequenceSize + payloadSlice.count), with: payloadSlice)
            packet.data = dataBytes

            packets.append(packet)
        }

        // Terminal ClipboardDataEnd packet:
        //   bytes 0-3: total chunk count (little-endian UInt32)
        //   bytes 4-7: total byte count of original data (little-endian UInt32)
        var endPacket = MWBPacket()
        endPacket.packageType = .clipboardDataEnd
        endPacket.setDataUInt32(UInt32(totalChunks), at: 0)
        endPacket.setDataUInt32(UInt32(data.count), at: 4)
        packets.append(endPacket)

        return packets
    }

    /// Extracts the total byte count from a ClipboardDataEnd packet, if present.
    private static func extractTotalBytes(from packets: [MWBPacket]) -> Int? {
        for packet in packets {
            guard packet.packageType == .clipboardDataEnd else { continue }
            return Int(packet.dataUInt32(at: 4))
        }
        return nil
    }

    /// Extracts and orders chunks from a packet array, filtering by the expected type.
    private static func extractChunks(from packets: [MWBPacket], expectedType: PackageType) -> [Chunk] {
        var chunks: [Chunk] = []

        for packet in packets {
            guard let ptype = packet.packageType else { continue }
            guard ptype == expectedType else { continue }

            let seq = packet.dataUInt32(at: 0)
            let dataField = packet.data
            let payload = Data(dataField[sequenceSize...])
            chunks.append(Chunk(sequence: seq, payload: payload))
        }

        // Sort by sequence number to guarantee correct order
        chunks.sort { $0.sequence < $1.sequence }

        // Validate contiguous sequence
        guard !chunks.isEmpty else { return [] }
        for (index, chunk) in chunks.enumerated() {
            guard chunk.sequence == UInt32(index) else { return [] }
        }

        return chunks
    }

    /// Reassembles ordered chunks into a single contiguous Data buffer.
    ///
    /// Uses `totalBytes` to trim the last chunk to its exact original size,
    /// avoiding loss of legitimate trailing zero bytes.
    private static func reassemble(chunks: [Chunk], totalBytes: Int) -> Data {
        guard !chunks.isEmpty else { return Data() }

        var result = Data()
        var bytesRemaining = totalBytes

        for chunk in chunks {
            let take = min(Int(chunk.payload.count), bytesRemaining)
            result.append(chunk.payload.prefix(take))
            bytesRemaining -= take
            if bytesRemaining <= 0 { break }
        }

        return result
    }
}
