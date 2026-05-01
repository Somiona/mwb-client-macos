import AppKit
import CoreGraphics
import os.log

/// Which screen edge triggers cursor crossing to the remote machine.
enum CrossingEdge: String, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom

    /// Default edge: right side is most common for side-by-side setups.
    static let `default`: CrossingEdge = .right
}

/// Information passed to the ``crossingStart`` callback when the cursor
/// reaches a screen edge and the debounce timer fires.
struct CrossingStartInfo: Sendable {
    /// The edge that was hit.
    let edge: CrossingEdge
    /// The cursor position in MWB virtual desktop coordinates at the time of crossing.
    let virtualPosition: (x: Int32, y: Int32)
    /// The cursor position in screen pixel coordinates at the time of crossing.
    let screenPosition: CGPoint
}

/// Detects when the cursor reaches a configured screen edge, signaling that
/// control should cross to the remote machine.
///
/// Usage:
/// 1. Set the ``crossingEdge`` and attach a ``crossingStart`` callback.
/// 2. Feed mouse events from ``InputCapture`` via ``updateCursorPosition(_:screenPoint:)``.
/// 3. When crossing starts, the coordinator sets ``isCrossingActive`` and enables
///    event suppression on InputCapture.
/// 4. When the remote machine returns control, call ``crossingDidEnd()`` to warp
///    the cursor back to the entry edge and resume monitoring.
///
/// Thread safety: All public API is intended to be called from the main thread
/// (matching InputCapture's threading model). The debounce timer is cancelled
/// and rescheduled synchronously.
final class EdgeDetector {

    // MARK: - Configuration

    /// The screen edge that triggers crossing.
    var crossingEdge: CrossingEdge = .default

    /// How close (in points) the cursor must be to the edge to be considered
    /// "at" the edge. Defaults to 2 points.
    var threshold: CGFloat = 2.0

    /// How long (in seconds) the cursor must remain at the edge before
    /// crossing is triggered. Prevents accidental triggers from brief
    /// edge touches. PowerToys uses 100ms (SKIP_PIXELS debounce).
    var debounceInterval: TimeInterval = 0.10

    /// Margin in points from screen corners where edge crossing is blocked.
    /// PowerToys uses 100px. Prevents accidental crossings when cursor
    /// approaches corners.
    var cornerBlockMargin: CGFloat = 100.0

    // MARK: - State

    /// Whether a crossing is currently in progress. When true, edge detection
    /// is suspended.
    private(set) var isCrossingActive = false

    /// The screen position where the cursor was when crossing started.
    /// Used to warp the cursor back on ``crossingDidEnd()``.
    private var crossingEntryPosition: CGPoint = .zero

    // MARK: - Callbacks

    /// Called when the cursor has been at the configured edge for longer than
    /// the debounce interval. The receiver (typically AppCoordinator) should
    /// enable event suppression and start forwarding input to the remote.
    var crossingStart: (@Sendable (CrossingStartInfo) -> Void)?

    // MARK: - Debounce

    /// The current debounce work item. Stored for cancellation when the cursor
    /// moves away from the edge before the debounce fires.
    private var debounceWork: DispatchWorkItem?

    // MARK: - Screen info cache

    /// Provider for display bounds in Quartz (top-left origin) coordinates.
    var screenBoundsProvider: () -> CGRect = { CGDisplayBounds(CGMainDisplayID()) }

    /// Cached display bounds.
    private var displayBounds: CGRect = .zero

    // MARK: - Public API

    /// Updates the detector with the latest cursor position.
    ///
    /// Should be called from ``InputCapture``'s mouse event callback with the
    /// MWB virtual desktop coordinates and the original screen coordinates.
    ///
    /// - Parameters:
    ///   - mouseData: The MWB mouse data (with virtual desktop coords 0-65535).
    ///   - screenPoint: The cursor position in macOS screen coordinates.
    func updateCursorPosition(_ mouseData: MouseData, screenPoint: CGPoint) {
        // While crossing is active, track the entry position but do not
        // trigger another crossing.
        if isCrossingActive {
            return
        }

        // Refresh display bounds on each update (handles display changes).
        displayBounds = screenBoundsProvider()

        // Skip edge detection if cursor is in a corner zone (PowerToys behavior)
        if isInCornerZone(screenPoint) {
            cancelDebounce()
            return
        }

        if isAtEdge(screenPoint) {
            // Cursor is at the edge. Start or keep the debounce timer.
            if debounceWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.triggerCrossing(mouseData: mouseData, screenPoint: screenPoint)
                }
                debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
            }
            // If debounceWork is already non-nil, the timer is running.
            // We do NOT reset it -- the original 50ms window is preserved.
        } else {
            // Cursor moved away from the edge. Cancel any pending debounce.
            cancelDebounce()
        }
    }

    /// Called by the coordinator when the remote machine returns cursor control.
    ///
    /// Warps the cursor back to the entry edge (slightly inset so it is visible)
    /// and resumes edge monitoring.
    func crossingDidEnd() {
        let warpTarget = insetPosition(crossingEntryPosition, for: crossingEdge, inset: threshold + 1)
        CGWarpMouseCursorPosition(warpTarget)
        
        if UserDefaults.standard.bool(forKey: "settings.hideMouseAtScreenEdge") {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        
        Logger.input.info("Edge crossing ended, warped cursor to (\(warpTarget.x), \(warpTarget.y))")

        isCrossingActive = false
        crossingEntryPosition = .zero
        cancelDebounce()
    }

    /// Immediately cancels any pending debounce timer without triggering crossing.
    ///
    /// Useful when the connection is lost or crossing is explicitly cancelled.
    func reset() {
        Logger.input.debug("Edge detector reset")
        isCrossingActive = false
        crossingEntryPosition = .zero
        cancelDebounce()
    }

    // MARK: - Edge detection

    /// Returns true if the given screen point is within ``threshold`` of
    /// the configured ``crossingEdge``.
    func isAtEdge(_ point: CGPoint) -> Bool {
        let bounds = displayBounds
        switch crossingEdge {
        case .left:
            return point.x - bounds.minX <= threshold
        case .right:
            return bounds.maxX - point.x <= threshold
        case .top:
            // Quartz: minY = top of screen
            return point.y - bounds.minY <= threshold
        case .bottom:
            // Quartz: maxY = bottom of screen
            return bounds.maxY - point.y <= threshold
        }
    }

    // MARK: - Crossing trigger

    /// Fires the ``crossingStart`` callback and enters the crossing-active state.
    private func triggerCrossing(mouseData: MouseData, screenPoint: CGPoint) {
        debounceWork = nil

        guard !isCrossingActive else { return }

        isCrossingActive = true
        crossingEntryPosition = screenPoint
        
        if UserDefaults.standard.bool(forKey: "settings.hideMouseAtScreenEdge") {
            CGDisplayHideCursor(CGMainDisplayID())
        }
        
        let edgeName = crossingEdge.rawValue
        Logger.input.info("Edge crossing triggered at \(edgeName) edge, screen: (\(screenPoint.x), \(screenPoint.y))")

        let info = CrossingStartInfo(
            edge: crossingEdge,
            virtualPosition: (mouseData.x, mouseData.y),
            screenPosition: screenPoint
        )
        crossingStart?(info)
    }

    // MARK: - Corner blocking

    /// Returns true if the cursor is within cornerBlockMargin of any screen corner.
    func isInCornerZone(_ point: CGPoint) -> Bool {
        guard UserDefaults.standard.bool(forKey: "settings.blockMouseAtCorners") else { return false }
        
        let bounds = displayBounds
        let margin = cornerBlockMargin

        let nearLeft = point.x - bounds.minX < margin
        let nearRight = bounds.maxX - point.x < margin
        let nearTop = point.y - bounds.minY < margin
        let nearBottom = bounds.maxY - point.y < margin

        // Block if near two perpendicular edges simultaneously (i.e., in a corner)
        return (nearLeft && nearTop) || (nearLeft && nearBottom)
            || (nearRight && nearTop) || (nearRight && nearBottom)
    }

    // MARK: - Helpers

    /// Cancels the debounce timer if one is pending.
    private func cancelDebounce() {
        debounceWork?.cancel()
        debounceWork = nil
    }

    /// Returns a point inset from the given edge by the specified amount.
    ///
    /// Used when warping the cursor back after crossing ends so the cursor
    /// appears slightly inside the screen (visible to the user).
    private func insetPosition(_ point: CGPoint, for edge: CrossingEdge, inset: CGFloat) -> CGPoint {
        switch edge {
        case .left:
            return CGPoint(x: point.x + inset, y: point.y)
        case .right:
            return CGPoint(x: point.x - inset, y: point.y)
        case .top:
            return CGPoint(x: point.x, y: point.y - inset)
        case .bottom:
            return CGPoint(x: point.x, y: point.y + inset)
        }
    }
}
