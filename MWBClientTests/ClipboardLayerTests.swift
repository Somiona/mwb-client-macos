import Testing
import Foundation
@testable import MWBClient

// MARK: - ClipboardCodec Tests

struct ClipboardCodecTests {

    // MARK: Text roundtrip

    @Test("Text encode/decode roundtrip preserves content")
    func testTextRoundtrip() {
        let original = "Hello, Mouse Without Borders!"
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Empty text roundtrip")
    func testEmptyTextRoundtrip() {
        let original = ""
        let packets = ClipboardCodec.encodeText(original)
        // Empty text produces 1 data packet + 1 end packet
        #expect(packets.count == 2)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Unicode text roundtrip")
    func testUnicodeTextRoundtrip() {
        let original = "こんにちは世界 🌍 Ñoño café résumé"
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Long text requires multiple chunks")
    func testLongTextChunking() {
        // 5000 chars of UTF-16 LE = 10000 bytes before compression.
        // Even with good compression, high-entropy data should need multiple 48-byte chunks.
        let original = String((0..<5000).map { Character(UnicodeScalar("A".unicodeScalars.first!.value + UInt32($0 % 26))!) })
        let packets = ClipboardCodec.encodeText(original)

        // Should have at least 2 data packets + 1 end packet
        let dataPackets = packets.filter { $0.packageType == .clipboardText }
        let endPackets = packets.filter { $0.packageType == .clipboardDataEnd }
        #expect(dataPackets.count >= 2)
        #expect(endPackets.count == 1)

        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Very long text roundtrip")
    func testVeryLongTextRoundtrip() {
        // 10KB of varied text
        let original = String((0..<10000).flatMap { _ in "ABCDEFGH".utf8 }.shuffled().map { Character(UnicodeScalar($0)) })
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    // MARK: Image roundtrip

    @Test("Image encode/decode roundtrip preserves raw bytes")
    func testImageRoundtrip() {
        let original = Data((0..<200).map { UInt8($0 % 256) })
        let packets = ClipboardCodec.encodeImage(original)
        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)

        // Trim trailing zeros from last chunk (48-byte field padding)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    @Test("Empty image roundtrip")
    func testEmptyImageRoundtrip() {
        let original = Data()
        let packets = ClipboardCodec.encodeImage(original)
        #expect(packets.count == 2) // 1 data + 1 end
        let decoded = ClipboardCodec.decodeImage(from: packets)
        // Empty data: reassembled is 48 bytes of zeros from the single empty chunk
        // decodeImage returns non-nil but it's padded zeros
        #expect(decoded != nil)
    }

    @Test("Image larger than one chunk produces multiple packets")
    func testImageMultipleChunks() {
        // 100 bytes -> needs ceil(100/48) = 3 chunks + 1 end = 4 packets
        let original = Data((0..<100).map { UInt8($0) })
        let packets = ClipboardCodec.encodeImage(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        let endPackets = packets.filter { $0.packageType == .clipboardDataEnd }
        #expect(dataPackets.count == 3)
        #expect(endPackets.count == 1)

        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    @Test("Image exactly one chunk (48 bytes)")
    func testImageExactlyOneChunk() {
        let original = Data((0..<48).map { UInt8($0) })
        let packets = ClipboardCodec.encodeImage(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        #expect(dataPackets.count == 1)

        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    // MARK: Packet structure

    @Test("All data packets have correct type and broadcast destination")
    func testPacketTypeAndDestination() {
        let textPackets = ClipboardCodec.encodeText("test")
        for packet in textPackets.dropLast() { // skip ClipboardDataEnd
            #expect(packet.packageType == .clipboardText)
            #expect(packet.des == MWBConstants.broadcastDestination)
        }
        #expect(textPackets.last?.packageType == .clipboardDataEnd)

        let imagePackets = ClipboardCodec.encodeImage(Data([0x01, 0x02]))
        for packet in imagePackets.dropLast() {
            #expect(packet.packageType == .clipboardImage)
            #expect(packet.des == MWBConstants.broadcastDestination)
        }
        #expect(imagePackets.last?.packageType == .clipboardDataEnd)
    }

    @Test("ClipboardDataEnd packet is always last")
    func testEndPacketAlwaysLast() {
        let packets = ClipboardCodec.encodeText("hello")
        #expect(packets.last?.packageType == .clipboardDataEnd)

        // Only one ClipboardDataEnd
        let endCount = packets.filter { $0.packageType == .clipboardDataEnd }.count
        #expect(endCount == 1)
    }

    // MARK: Decode with wrong type returns nil

    @Test("Decoding text packets as image returns nil")
    func testWrongTypeDecode() {
        let packets = ClipboardCodec.encodeText("hello")
        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded == nil)
    }

    @Test("Decoding empty packet array returns nil")
    func testDecodeEmptyArray() {
        #expect(ClipboardCodec.decodeText(from: []) == nil)
        #expect(ClipboardCodec.decodeImage(from: []) == nil)
    }

    @Test("Decoding only ClipboardDataEnd returns nil")
    func testDecodeOnlyEndPacket() {
        var endPacket = MWBPacket()
        endPacket.packageType = .clipboardDataEnd
        #expect(ClipboardCodec.decodeText(from: [endPacket]) == nil)
        #expect(ClipboardCodec.decodeImage(from: [endPacket]) == nil)
    }

    // MARK: Compression

    @Test("Compressed text is smaller than uncompressed for repeated content")
    func testCompressionReducesSize() {
        let original = String(repeating: "Hello World! ", count: 100)
        let packets = ClipboardCodec.encodeText(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardText }
        let totalPayload = dataPackets.count * MWBConstants.dataFieldSize
        let utf16Size = original.utf16.count * 2
        // Compressed + chunking overhead should be smaller than raw UTF-16
        #expect(totalPayload < utf16Size)
    }

    // MARK: Large data stress test

    @Test("1MB image data roundtrip")
    func testLargeImageRoundtrip() {
        let original = Data((0..<1_000_000).map { UInt8($0 % 256) })
        let packets = ClipboardCodec.encodeImage(original)
        // ceil(1_000_000 / 48) = 20834 chunks + 1 end
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        #expect(dataPackets.count == 20_834)

        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    // MARK: Single character and special text

    @Test("Single ASCII character roundtrip")
    func testSingleCharRoundtrip() {
        let original = "A"
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Text with newlines and tabs roundtrip")
    func testWhitespaceTextRoundtrip() {
        let original = "line1\nline2\r\nline3\ttab\ronly_cr"
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    @Test("Text with null bytes preserved through UTF-16 LE encoding")
    func testTextWithNullChars() {
        // Some clipboard content may contain null characters
        let original = "before\u{0000}after"
        let packets = ClipboardCodec.encodeText(original)
        let decoded = ClipboardCodec.decodeText(from: packets)
        #expect(decoded == original)
    }

    // MARK: Chunk boundary tests

    @Test("Image exactly at chunk boundary (48*N bytes) roundtrip")
    func testImageAtChunkBoundary() {
        // 96 bytes = 2 full chunks
        let original = Data((0..<96).map { UInt8($0 % 256) })
        let packets = ClipboardCodec.encodeImage(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        #expect(dataPackets.count == 2)

        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    @Test("Image one byte less than chunk boundary (48*N - 1) roundtrip")
    func testImageOneBelowChunkBoundary() {
        // 47 bytes = 1 chunk (partially filled)
        let original = Data((0..<47).map { UInt8($0 % 256) })
        let packets = ClipboardCodec.encodeImage(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        #expect(dataPackets.count == 1)

        let decoded = ClipboardCodec.decodeImage(from: packets)
        #expect(decoded != nil)
        let trimmed = decoded!.prefix(original.count)
        #expect(trimmed == original)
    }

    // MARK: Packet data field verification

    @Test("First data packet contains the beginning of the payload")
    func testFirstPacketPayloadContent() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])
        let packets = ClipboardCodec.encodeImage(original)
        let firstDataPacket = packets.first { $0.packageType == .clipboardImage }
        #expect(firstDataPacket != nil)

        let data = firstDataPacket!.data
        #expect(data[0] == 0xDE)
        #expect(data[1] == 0xAD)
        #expect(data[2] == 0xBE)
        #expect(data[3] == 0xEF)
        #expect(data[4] == 0x01)
        #expect(data[5] == 0x02)
        // Remaining bytes should be zero-padded
        for i in 6..<MWBConstants.dataFieldSize {
            #expect(data[i] == 0)
        }
    }

    @Test("Mixed packet types are filtered during decode")
    func testMixedPacketTypesFiltered() {
        var textPackets = ClipboardCodec.encodeText("hello")
        var imagePacket = MWBPacket()
        imagePacket.packageType = .clipboardImage
        var dummyData = Data(count: MWBConstants.dataFieldSize)
        dummyData[0] = 0xFF
        imagePacket.data = dummyData

        // Insert an image packet in the middle of text packets
        textPackets.insert(imagePacket, at: 1)

        // Decoding as text should only use clipboardText packets
        let decoded = ClipboardCodec.decodeText(from: textPackets)
        #expect(decoded == "hello")
    }

    @Test("Exact chunk count calculation")
    func testExactChunkCount() {
        // 49 bytes -> ceil(49/48) = 2 data chunks + 1 end = 3 packets
        let original = Data((0..<49).map { UInt8($0) })
        let packets = ClipboardCodec.encodeImage(original)
        let dataPackets = packets.filter { $0.packageType == .clipboardImage }
        #expect(dataPackets.count == 2)
        #expect(packets.count == 3) // 2 data + 1 end
    }
}


