# Clipboard file transfer fixes (Windows↔Mac)

## Context

Cross-device clipboard sync works for text and images, but files are broken in both directions:

1. **Windows → Mac**: transfer succeeds but the saved/pasted filename is the entire Windows source path, e.g. `Users/edgeneko/Pictures/D:\OneDrive - Aiursoft\cg\69456412_p0.png`. Root cause: the reference sender (`SocketStuff.SendClipboardData`) puts the **full source path** in the 1024-byte transfer header (`{size}*{name}`), and the Windows receiver reduces it with .NET `Path.GetFileName` (splits on both `\` and `/`). The Mac's `ClipboardChannel.receiveFile` (ClipboardChannel.swift:648) uses `(name as NSString).lastPathComponent`, which only splits on `/` — so `D:\OneDrive - Aiursoft\cg\x.png` stays one giant filename component.
2. **Mac → Windows**: Finder ⌘C on a file, then Ctrl+V on Windows does nothing and Explorer shows no Paste option. Root cause (empirically verified with an isolated `NSPasteboard.withUniqueName()`): `NSImage(pasteboard:)` **resolves file URLs of image files** and returns non-nil. `ClipboardManager.checkAndSendClipboard` checks text → image → files in that order, so copying e.g. `69456412_p0.png` in Finder is sent as an *image*, never staged as a file. Windows then holds an image clipboard — Explorer shows no Paste. (Verified: a file-URL-only pasteboard yields `string(forType:.string) == nil`, `NSImage(pasteboard:) != nil` for image files, `nil` for non-image files.) The reference priority is the same (text > image > FileDropList, FormHelper.cs WM_DRAWCLIPBOARD handler), but Win32 `ContainsImage()` is never true for a file-drop copy — the Mac must replicate that distinction.

The beat/pull/serve channel itself works in both directions (Windows→Mac pull proves outbound; Mac→Windows uses the same symmetric `Clipboard.ShakeHand` with the roles swapped, and the Mac listener on 15100 is started by `AppCoordinator.startServicesAfterConnection`), so no channel/protocol changes are needed. The Mac must keep serving the full POSIX path in the header (reference fidelity; Windows `Path.GetFileName` handles `/`).

## Approach

### 1. Reduce inbound transfer-header names to the final component (Windows→Mac filename fix)

File: `MWBClient/Clipboard/ClipboardChannel.swift`

- Add a static helper next to `encodeHeader`/`parseHeader` (~line 800 region, "Transfer framing" section):

```swift
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
```

- In `receiveFile` (~line 648), replace:
  `let basename = (name as NSString).lastPathComponent`
  with:
  `let basename = Self.baseFileName(of: name)`
- Error headers ("Folder is not supported", "File too big", "not found") never reach `receiveFile` (they have `size == 0` and take the warning branch in `receiveTransfer`), so no other call sites exist. `handleChannelFile`/`writeFileToPasteboard` consume the returned URL and need no changes.

### 2. Stop treating Finder file copies as images (Mac→Windows fix)

File: `MWBClient/Clipboard/ClipboardManager.swift`

- Convert `readImageFromPasteboard()` (instance, reads `.general`) to an internal static pure function taking a pasteboard, and gate it on file URLs (mirrors reference: a FileDropList never takes the CF_BITMAP branch):

```swift
/// Returns PNG data for direct image content on the pasteboard, or nil.
/// A Finder file copy exposes only a file URL, which NSImage(pasteboard:)
/// would otherwise load as an image — the reference never treats a
/// FileDropList as CF_BITMAP, so a file URL must fall through to the file
/// branch. Static + parameterized for isolated-pasteboard testing.
static func readImage(from pasteboard: NSPasteboard) -> Data? {
    guard pasteboard.types?.contains(.fileURL) != true else { return nil }
    guard let image = NSImage(pasteboard: pasteboard) else {
        mwbError(MWBLog.clipboard, "Failed to get image from pasteboard")
        return nil
    }
    // … existing tiffRepresentation → NSBitmapImageRep → PNG body unchanged …
}
```

- Convert `readFilesFromPasteboard()` the same way for testability: `static func readFiles(from pasteboard: NSPasteboard) -> [URL]?` (body unchanged; keep the `.fileURL` type check). `readTextFromPasteboard()` stays as-is.
- Update the call sites in `checkAndSendClipboard()` (the method already begins with `let pasteboard = NSPasteboard.general`):
  - `if syncImages, let imageData = readImage(from: pasteboard) {`
  - `if syncFiles, let urls = readFiles(from: pasteboard) {`
- Behavior after the fix: Finder ⌘C on any file → text branch nil (verified), image branch nil (gate), file branch stages `.file(url)` + sends the type-69 beat. Crossing to Windows fires MachineSwitched (already implemented) → Windows pulls from Mac:15100 → Mac serves full POSIX path → Windows `Path.GetFileName` saves it and sets the FileDropList → Explorer paste works. Apps that put a file URL **and** direct image data still send as image (matches reference priority: text > image > file).

### 3. Regression tests

- `MWBClientTests/ClipboardFormatTests.swift` — add to the header test group:

```swift
func testBaseFileNameSplitsWindowsAndPosixSeparators() {
    XCTAssertEqual(ClipboardChannel.baseFileName(of: "D:\\OneDrive - Aiursoft\\cg\\69456412_p0.png"), "69456412_p0.png")
    XCTAssertEqual(ClipboardChannel.baseFileName(of: "/Users/edgeneko/Pictures/img.png"), "img.png")
    XCTAssertEqual(ClipboardChannel.baseFileName(of: "file.png"), "file.png")
    XCTAssertEqual(ClipboardChannel.baseFileName(of: "C:\\dir\\sub\\"), "sub")
    XCTAssertEqual(ClipboardChannel.baseFileName(of: "plain"), "plain")
}
```

- New file `MWBClientTests/ClipboardPasteboardPriorityTests.swift` (uses only `NSPasteboard.withUniqueName()` — never `.general`; temp-file pattern copied from `ClipboardChannelLoopbackTests.testPullReceivesStagedFile`):

```swift
final class ClipboardPasteboardPriorityTests: XCTestCase {
    func testFinderStyleImageFileCopyIsNotInterceptedAsImage() throws {
        // 1×1 PNG written to a temp file via NSBitmapImageRep.
        // Isolated pasteboard with only the file URL (Finder ⌘C shape):
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        XCTAssertNil(ClipboardManager.readImage(from: pb))           // gate: file copy is not an image
        XCTAssertEqual(ClipboardManager.readFiles(from: pb), [fileURL]) // file branch sees it
    }
    func testDirectImageDataIsStillReadAsImage() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([NSImage(size: NSSize(width: 2, height: 2))]) // writes .tiff
        XCTAssertNotNil(ClipboardManager.readImage(from: pb))
    }
}
```

- After adding the test file, run `make generate` (xcodegen) so it joins the `MWBClientTests` target (project.yml globs `MWBClientTests`).

### 4. Protocol doc

File: `docs/protocol/06. clipboard sync.md` — in section 3/4 where the 1024-byte header is described, add one paragraph: the header `name` field carries the sender's **full source path** (e.g. `D:\OneDrive\cg\x.png` from Windows, `/Users/x/y.png` from a mac client); receivers must reduce it to the final path component splitting on **both** `\` and `/` (.NET `Path.GetFileName` semantics). This is the behavior the Windows reference relies on.

## Critical files & anchors

- `MWBClient/Clipboard/ClipboardChannel.swift` — `receiveFile` (~line 648, basename) and the "Transfer framing" section (`encodeHeader`/`parseHeader`, ~line 800) for the new `baseFileName(of:)`.
- `MWBClient/Clipboard/ClipboardManager.swift` — `readImageFromPasteboard`/`readFilesFromPasteboard` (~lines 419–451) and their call sites in `checkAndSendClipboard` (~lines 346/357/375).
- `MWBClientTests/ClipboardChannelLoopbackTests.swift` — temp-file fixture pattern to copy for the new pasteboard test.
- `docs/protocol/06. clipboard sync.md` — header-name documentation.

## Verification

1. Regenerate + full test suite (CI command):
   ```
   make generate
   xcodebuild test -project MWBClient.xcodeproj -scheme MWBClientTests -destination 'platform=macOS'
   ```
   Expected: all existing tests pass (incl. `testPullReceivesStagedFile`, which uses a POSIX path and is unaffected by the separator change) plus the 3 new tests above.
2. New-behavior proof (no Windows machine needed):
   - `testBaseFileNameSplitsWindowsAndPosixSeparators` proves the exact reported name `D:\OneDrive - Aiursoft\cg\69456412_p0.png` → `69456412_p0.png`.
   - `testFinderStyleImageFileCopyIsNotInterceptedAsImage` proves the poll no longer hijacks a Finder image-file copy.
3. Manual end-to-end against the real Windows machine (user validates; needs the paired PowerToys setup):
   - Windows: copy `D:\...\69456412_p0.png` → move mouse to Mac → ⌘V in Finder → file appears named `69456412_p0.png` (no `D:\` prefix).
   - Mac: Finder ⌘C the same PNG → move mouse to Windows → Ctrl+V in Explorer → the file is pasted; right-click shows Paste.

## Assumptions & contingencies

- The Mac serves the full POSIX path in the transfer header (unchanged) — Windows `Path.GetFileName` reduces it; this matches the reference sender, which also transmits full paths.
- Known shared limitation (same as the reference, not fixed here): a `*` in a Mac filename corrupts header parsing on the Windows side (`Split('*')`); `*` is illegal in Windows filenames so the reference has the identical behavior.
- If manual testing still shows no Paste on Windows for a **non-image** file after fix 2, the failure is on the Windows pull path (`IsConnectedByAClientSocketTo` → ClipboardAsk fallback or MachinePool name resolution); check the Mac log for `ClipboardAsk from machine …; pushing staged data` and the PowerToys log before touching Mac code — the Mac side implements both pull-serve and ask-push.
- If the served file arrives on Windows with a mangled name containing `/`, leave the Mac serve path alone (Windows `Path.GetFileName` is the reducer); only the *receive* side basename may be adapted.
