import XCTest
@testable import MWBClient

/// Verifies the clipboard text segment format (TXT/RTF/HTM + separator) and
/// the clipboard channel's 1024-byte transfer header framing.
final class ClipboardFormatTests: XCTestCase {

    // MARK: - Text segment format

    func testTextTypeSeparatorMatchesPowerToys() {
        XCTAssertEqual(ClipboardCodec.textTypeSeparator, "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}")
    }

    func testMakeTextPayloadBuildsSegments() {
        let payload = ClipboardCodec.makeTextPayload(text: "hello", rtf: "{\\rtf1}", html: "<b>hello</b>")
        let expected = "TXThello" + ClipboardCodec.textTypeSeparator
            + "RTF{\\rtf1}" + ClipboardCodec.textTypeSeparator
            + "HTM<b>hello</b>" + ClipboardCodec.textTypeSeparator
        XCTAssertEqual(payload, expected)
    }

    func testMakeTextPayloadOmitsEmptySegments() {
        let payload = ClipboardCodec.makeTextPayload(text: "hello", rtf: nil, html: nil)
        XCTAssertEqual(payload, "TXThello" + ClipboardCodec.textTypeSeparator)
        let withEmpty = ClipboardCodec.makeTextPayload(text: "hello", rtf: "", html: "")
        XCTAssertEqual(withEmpty, payload, "empty RTF/HTML segments are omitted too")
    }

    func testEncodeDecodeTextRoundTripWithSegments() {
        let packets = ClipboardCodec.encodeText(
            "Grüße — multiline\ntext ✓",
            rtf: "{\\rtf1 hi}",
            html: "<p>hi</p>")
        let decoded = ClipboardCodec.decodeText(from: packets)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.plain, "Grüße — multiline\ntext ✓")
        XCTAssertEqual(decoded?.rtf, "{\\rtf1 hi}")
        XCTAssertEqual(decoded?.html, "<p>hi</p>")
    }

    func testEncodeDecodePlainTextOnly() {
        let packets = ClipboardCodec.encodeText("plain")
        let decoded = ClipboardCodec.decodeText(from: packets)
        XCTAssertEqual(decoded?.plain, "plain")
        XCTAssertNil(decoded?.rtf)
        XCTAssertNil(decoded?.html)
    }

    func testEncodeDecodeLargeText() {
        // Spans many 48-byte chunks and exercises the Deflate round trip.
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 500)
        let packets = ClipboardCodec.encodeText(text)
        XCTAssertEqual(ClipboardCodec.decodeText(from: packets)?.plain, text)
    }

    func testDecodeLegacyPlainTextWithoutSeparator() {
        // Old senders ship a bare string with no TXT/SEP framing; the
        // reference receiver accepts it as plain text.
        let legacyCompressed = ClipboardCodec.compressData("just text".data(using: .utf16LittleEndian)!)
        let legacy = ClipboardCodec.decompressData(legacyCompressed)
        let decoded = ClipboardCodec.decodeTextPayload(legacy)
        XCTAssertEqual(decoded.plain, "just text")
        XCTAssertNil(decoded.rtf)
        XCTAssertNil(decoded.html)
    }

    func testDecodeUnframedFirstSegmentFallsBackToPlain() {
        // Reference SetClipboardData: an unframed FIRST segment becomes the
        // plain text.
        let payload = "no tags here" + ClipboardCodec.textTypeSeparator + "RTFr"
        let decoded = ClipboardCodec.decodeTextPayload(payload)
        XCTAssertEqual(decoded.plain, "no tags here")
        XCTAssertEqual(decoded.rtf, "r")
    }

    // MARK: - Image codec

    func testEncodeDecodeImageRoundTrip() {
        var bytes = Data()
        for i in 0..<5000 {
            bytes.append(UInt8(truncatingIfNeeded: i))
        }
        let packets = ClipboardCodec.encodeImage(bytes)
        let decoded = ClipboardCodec.decodeImage(from: packets)
        // The final chunk is zero-padded to the full 48-byte data field
        // (the reference receiver consumes all 48 bytes per packet; PNG
        // decoders ignore the trailing zeros).
        let padded = 48 * ((bytes.count + 47) / 48)
        XCTAssertEqual(decoded?.count, padded)
        XCTAssertEqual(Data(decoded!.prefix(bytes.count)), bytes)
        XCTAssertTrue(decoded!.suffix(padded - bytes.count).allSatisfy { $0 == 0 })
    }

    // MARK: - Channel header framing

    func testHeaderIsExactly1024BytesUTF16LEWithZeroPadding() {
        let header = ClipboardChannel.encodeHeader(size: 12345, name: "text")
        XCTAssertEqual(ClipboardChannel.headerSize, 1024)
        XCTAssertEqual(header.count, ClipboardChannel.headerSize)
        // First code unit of "12345*text" in UTF-16LE: '1' = 0x31 0x00.
        XCTAssertEqual(header[header.startIndex], 0x31)
        XCTAssertEqual(header[header.index(after: header.startIndex)], 0x00)
        // Everything after the string is zero padding.
        let stringBytes = "12345*text".utf16.count * 2
        XCTAssertTrue(header.suffix(header.count - stringBytes).allSatisfy { $0 == 0 })
    }

    func testHeaderRoundTrip() {
        let cases: [(Int64, String)] = [
            (12345, "text"),
            (42, "image"),
            (100, "/Users/x/file.txt"),
        ]
        for (size, name) in cases {
            let header = ClipboardChannel.encodeHeader(size: size, name: name)
            let parsed = ClipboardChannel.parseHeader(header)
            XCTAssertNotNil(parsed, "header for \(name)")
            XCTAssertEqual(parsed?.size, size)
            XCTAssertEqual(parsed?.name, name)
        }
    }

    func testHeaderRoundTripLargeSize() {
        let size: Int64 = 100 * 1024 * 1024  // 100 MB
        let header = ClipboardChannel.encodeHeader(size: size, name: "image")
        XCTAssertEqual(ClipboardChannel.parseHeader(header)?.size, size)
    }

    func testHeaderParseFolderNotSupported() {
        let name = "C:\\dir - Folder is not supported, zip it first!"
        let header = ClipboardChannel.encodeHeader(size: 0, name: name)
        let parsed = ClipboardChannel.parseHeader(header)
        XCTAssertEqual(parsed?.size, 0)
        XCTAssertEqual(parsed?.name, name)
    }

    func testHeaderParseFileTooBig() {
        let name = "/Users/x/huge.zip - File too big (greater than 100MB), please drag and drop the file instead!"
        let header = ClipboardChannel.encodeHeader(size: 0, name: name)
        let parsed = ClipboardChannel.parseHeader(header)
        XCTAssertEqual(parsed?.size, 0)
        XCTAssertEqual(parsed?.name, name)
    }

    func testHeaderParseRejectsGarbage() {
        // 'A's with no '*' separator.
        XCTAssertNil(ClipboardChannel.parseHeader(Data(repeating: 0x41, count: 1024)))
        // Non-numeric size prefix.
        let noNumber = "abc*text".data(using: .utf16LittleEndian)! + Data(count: 1024 - 16)
        XCTAssertNil(ClipboardChannel.parseHeader(noNumber))
    }

    func testBaseFileNameSplitsWindowsAndPosixSeparators() {
        // The reference sender transmits the full source path in the header.
        XCTAssertEqual(
            ClipboardChannel.baseFileName(of: "D:\\OneDrive - Aiursoft\\cg\\69456412_p0.png"),
            "69456412_p0.png")
        XCTAssertEqual(ClipboardChannel.baseFileName(of: "/Users/edgeneko/Pictures/img.png"), "img.png")
        XCTAssertEqual(ClipboardChannel.baseFileName(of: "file.png"), "file.png")
        XCTAssertEqual(ClipboardChannel.baseFileName(of: "C:\\dir\\sub\\"), "sub")
        XCTAssertEqual(ClipboardChannel.baseFileName(of: "plain"), "plain")
    }
}
