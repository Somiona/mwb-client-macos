import AppKit
import Foundation
import os.log

/// Manages the Mouse Without Borders Drag & Drop protocol state machine.
///
/// When the Mac is the drag source (a Mac-local drag crossing to the remote
/// machine), a transient invisible window under the cursor captures the native
/// macOS drag session; the captured file is staged on the clipboard channel
/// and announced with ClipboardDragDrop (70) + ClipboardDragDropOperation (75).
///
/// When the Mac is the drop target, injected drags arrive as plain button and
/// move events (no local OLE drag session exists on macOS for them), so the
/// file is pulled over the clipboard channel on the remote mouse-up.
@MainActor
final class DragDropManager: NSObject, NSDraggingDestination {
    static let shared = DragDropManager()

    private let logger = Logger(subsystem: "com.mwb.client", category: "DragDrop")
    private var dropWindow: NSWindow?

    // State machine variables

    /// Mac is the drag source and has announced a file (70 + 75 sent).
    private(set) var isDragging = false

    /// Mac is the drop target (received 75 addressed to this machine).
    private(set) var isDropping = false

    /// Local (physical) mouse button state.
    private(set) var mouseDown = false

    /// Remote (injected) mouse button state.
    private(set) var remoteMouseDown = false

    /// The machine that sent ExplorerDragDrop (72): the target of our drag.
    private(set) var dropMachineID: MachineID = .none

    /// The machine that announced a drag via ClipboardDragDrop (70).
    private(set) var dragSourceMachineID: MachineID = .none

    private var lastDragFile: String?

    /// Auto-hides the drop window when no drag session entered it in time.
    private var hideWindowTask: Task<Void, Never>?

    private override init() {
        super.init()
        setupDropWindow()
    }

    private func setupDropWindow() {
        // Create an invisible, always-on-top window.
        // All NSWindow initialisation and property mutations are main-actor isolated;
        // the @MainActor annotation on this class satisfies that requirement.
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = false // We need to catch drag events
        window.registerForDraggedTypes([.fileURL, .string])

        self.dropWindow = window
    }

    // MARK: - Local mouse (Mac is potentially the drag source)

    /// Called when the local mouse button is pressed/released.
    func handleLocalMouseButton(down: Bool) {
        mouseDown = down
        if !down && isDragging {
            // The remote machine pulls the staged file when it sees the
            // forwarded mouse-up; the staged drag file must stay put until
            // then, so only the announcement state is cleared here.
            isDragging = false
            logger.info("Local drag ended")
        }
    }

    // MARK: - Remote mouse (Mac is potentially the drop target)

    /// Called on injected (remote) mouse button transitions.
    func handleRemoteMouseButton(down: Bool) {
        remoteMouseDown = down
        if !down && isDropping {
            isDropping = false
            logger.info("Drop detected, pulling remote clipboard data")
            onDropRequested?(.desktop)
        }
    }

    // MARK: - ExplorerDragDrop (72): are we dragging?

    /// Called when receiving ExplorerDragDrop (Type 72) from the machine being
    /// entered. It asks whether this machine (being left) is dragging a file.
    func handleExplorerDragDropRequest(from source: MachineID) {
        dropMachineID = source

        // The invisible window only matters for Mac-LOCAL drag sessions;
        // remote-initiated drags deliver their file via the channel pull.
        guard mouseDown && !remoteMouseDown else { return }
        showDropWindowUnderCursor()
    }

    /// Called when the cursor crosses toward the remote machine while the
    /// local mouse is held down: a Mac-local drag may be in progress, so
    /// capture it before the cursor leaves.
    func beginLocalDragCheck() {
        guard mouseDown else { return }
        showDropWindowUnderCursor()
    }

    private func showDropWindowUnderCursor() {
        // Show the invisible window under the cursor to catch the drag.
        // Already on the main actor; no extra dispatch needed.
        let mouseLocation = NSEvent.mouseLocation
        dropWindow?.setFrame(
            NSRect(x: mouseLocation.x - 50, y: mouseLocation.y - 50, width: 100, height: 100),
            display: true)
        dropWindow?.orderFrontRegardless()

        hideWindowTask?.cancel()
        hideWindowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500 ms
            guard !Task.isCancelled else { return }
            self?.dropWindow?.orderOut(nil)
        }
    }

    // MARK: - NSDraggingDestination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            lastDragFile = url.path
            logger.info("Captured drag file: \(url.path)")

            hideWindowTask?.cancel()

            // Broadcast ClipboardDragDrop (70) + ClipboardDragDropOperation (75)
            // and stage the file on the clipboard channel via the coordinator.
            notifyDragDetected(path: url.path)

            // Hide the window once we have the file
            dropWindow?.orderOut(nil)
            return .copy
        }
        return []
    }

    private var onDragDetected: ((String) -> Void)?
    func setDragDetectedCallback(_ callback: @escaping (String) -> Void) {
        self.onDragDetected = callback
    }

    /// Requests a clipboard-channel pull (remote machine has data for us).
    var onDropRequested: ((ClipboardPostAction) -> Void)?
    func setDropRequestedCallback(_ callback: @escaping (ClipboardPostAction) -> Void) {
        self.onDropRequested = callback
    }

    private func notifyDragDetected(path: String) {
        isDragging = true
        onDragDetected?(path)
    }

    // MARK: - ClipboardDragDrop (70) / Operation (75) / End (71)

    /// Called when receiving ClipboardDragDrop (Type 70): the sender has a
    /// drag file ready. Records the drag source; the drop target role is
    /// only assumed once 75 (addressed to us) arrives.
    func handleDragAnnounced(from source: MachineID) {
        dragSourceMachineID = source
        logger.info("Machine \(source.rawValue) announced a drag file")
    }

    /// Called when receiving ClipboardDragDropOperation (Type 75) addressed to
    /// this machine: we are the drop target. The pull happens on mouse-up.
    func handleDropBegin() {
        isDropping = true
        logger.info("Remote drag announced, entering drop mode")
    }

    /// Called when receiving ClipboardDragDropEnd (Type 71): the remote drag
    /// was cancelled.
    func handleDragDropEnd() {
        isDropping = false
        logger.info("Remote drag cancelled")
    }

    // MARK: - Channel-driven resets

    /// Called when the clipboard channel accepts a connection, mirroring the
    /// reference `SendOrReceiveClipboardData` accept path.
    func resetForChannelAccept() {
        isDropping = false
        isDragging = false
        dragSourceMachineID = .none
    }

    /// Cancels a Mac-local drag that came back without a drop (reference
    /// DragDropStep11).
    func cancelLocalDrag() {
        isDragging = false
        lastDragFile = nil
        logger.info("Local drag cancelled")
    }
}
