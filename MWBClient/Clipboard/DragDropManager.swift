import AppKit
import Foundation
import os.log

/// Manages the Mouse Without Borders Drag & Drop protocol state machine.
/// 
/// This implementation uses a persistent invisible window on the shared edge
/// to capture native macOS drag events.
@MainActor
final class DragDropManager: NSObject, NSDraggingDestination {
    static let shared = DragDropManager()
    
    private let logger = Logger(subsystem: "com.mwb-client", category: "DragDrop")
    private var dropWindow: NSWindow?
    
    // State machine variables
    private var isDragging = false
    private var isDropping = false
    private var mouseDown = false
    private var lastDragFile: String?
    
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
    
    /// Called when the local mouse button is pressed/released.
    func handleLocalMouseButton(down: Bool) {
        self.mouseDown = down
        if !down {
            if isDragging {
                isDragging = false
                logger.info("Local drag ended")
            }
        }
    }
    
    /// Called when the cursor crosses to the remote machine.
    func handleCrossingToRemote() {
        if mouseDown {
            // Potential drag starting from Mac to Windows.
            // In MWB protocol, the DESTINATION machine asks the SOURCE machine.
            // So we wait for the remote to send ExplorerDragDrop.
        }
    }
    
    /// Called when receiving ExplorerDragDrop (Type 72) from remote.
    /// Remote is asking if we are currently dragging a file.
    func handleExplorerDragDropRequest() {
        guard mouseDown else { return }
        
        // Show the invisible window under the cursor to catch the drag
        // Already on the main actor; no extra dispatch needed.
        let mouseLocation = NSEvent.mouseLocation
        self.dropWindow?.setFrame(NSRect(x: mouseLocation.x - 50, y: mouseLocation.y - 50, width: 100, height: 100), display: true)
        self.dropWindow?.orderFrontRegardless()
        // The window will now receive draggingEntered if a drag is in progress
    }
    
    // MARK: - NSDraggingDestination
    
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            lastDragFile = url.path
            logger.info("Captured drag file: \(url.path)")
            
            // Step 06: Broadcast ClipboardDragDrop
            // In our implementation, we'll notify the coordinator to send the packet
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
    
    private func notifyDragDetected(path: String) {
        isDragging = true
        onDragDetected?(path)
    }
    
    /// Called when receiving ClipboardDragDrop (Type 70) from remote.
    /// Remote is announcing they have a file ready for us to drop.
    func handleRemoteDragAnnounced() {
        isDropping = true
        logger.info("Remote drag announced, entering drop mode")
        // In drop mode, we wait for MouseUp to trigger the pull
    }
    
    /// Called when the remote mouse button is released on the Mac.
    func handleRemoteMouseUp() {
        if isDropping {
            isDropping = false
            logger.info("Drop detected, requesting remote clipboard")
            // Trigger clipboard pull
            NotificationCenter.default.post(name: .mwbTriggerClipboardPull, object: nil)
        }
    }
}

extension Notification.Name {
    static let mwbTriggerClipboardPull = Notification.Name("mwbTriggerClipboardPull")
}
