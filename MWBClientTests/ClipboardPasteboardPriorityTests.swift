import XCTest
@testable import MWBClient

/// Proves the clipboard poll priority: a Finder file copy (private Finder
/// markers + file URL + filename text + TIFF icon) must fall through to the
/// file branch, never be loaded as an image — mirroring the reference, where
/// a FileDropList never takes the CF_BITMAP branch. A bare file URL from a
/// screenshot/copy-as-image tool, in contrast, resolves as an image, matching
/// how macOS apps paste it. All tests use isolated pasteboards
/// (`NSPasteboard.withUniqueName()`), never `NSPasteboard.general`.
final class ClipboardPasteboardPriorityTests: XCTestCase {

    /// A 1×1 PNG written to a temp file (an image file on disk).
    private func makeImageFileURL() throws -> URL {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let png = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwb-pasteboard-\(UUID().uuidString).png")
        try png.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The private flavors a real Finder ⌘C file copy carries alongside the
    /// file URL (verified against a live Finder copy).
    private let finderMarkers: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("com.apple.finder.noderef"),
        NSPasteboard.PasteboardType("fndf"),
    ]

    func testFinderStyleImageFileCopyIsNotInterceptedAsImage() throws {
        let fileURL = try makeImageFileURL()

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        XCTAssertNotEqual(pasteboard.addTypes(finderMarkers, owner: nil), 0)

        // Gate: a file copy is never an image, even though the file itself
        // contains image data NSImage(pasteboard:) would resolve.
        XCTAssertNil(ClipboardManager.readImage(from: pasteboard))
        // The file branch still sees it (FileDropList equivalent).
        XCTAssertEqual(ClipboardManager.readFiles(from: pasteboard), [fileURL])
    }

    func testDirectImageDataIsStillReadAsImage() {
        // An NSImage backed by real pixels (a bare NSImage(size:) has no
        // representations, so tiffRepresentation would be nil).
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let cgImage = bitmap?.cgImage
        let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: 2, height: 2)) }

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        // Writing an NSImage puts TIFF data on the pasteboard (Preview /
        // screenshot / browser "Copy Image" shape).
        XCTAssertTrue(pasteboard.writeObjects([image].compactMap { $0 }))

        XCTAssertNotNil(ClipboardManager.readImage(from: pasteboard))
    }

    func testBareFileURLFromImageToolIsReadAsImage() throws {
        let fileURL = try makeImageFileURL()

        // Screenshot app / "copy as image" shape: a bare file URL with no
        // Finder markers. Pasting this into an app yields the image content,
        // so it must be synced as an image, not as a file.
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        XCTAssertNotNil(ClipboardManager.readImage(from: pasteboard))
        XCTAssertTrue(ClipboardManager.isFinderFileCopy(pasteboard) == false)
    }

    func testFinderFileCopyShapeAlwaysTakesTheFileBranch() throws {
        let fileURL = try makeImageFileURL()

        // The real Finder ⌘C shape: file URL + filename as string + TIFF
        // icon (verified against a live Finder copy). All content branches
        // except the file branch must decline.
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        XCTAssertNotEqual(pasteboard.addTypes(finderMarkers, owner: nil), 0)
        XCTAssertNotEqual(pasteboard.addTypes([.string], owner: nil), 0)
        XCTAssertTrue(pasteboard.setString("requirements.txt", forType: .string))

        XCTAssertNil(ClipboardManager.readText(from: pasteboard))   // filename is not the copy's payload
        XCTAssertNil(ClipboardManager.readImage(from: pasteboard))  // file icon / image file is not the payload
        XCTAssertEqual(ClipboardManager.readFiles(from: pasteboard), [fileURL])
    }
}
