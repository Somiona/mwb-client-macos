import AppKit
import CoreGraphics

/// Queries NSScreen and CGDisplay for screen dimensions and provides
/// mapping between macOS screen coordinates and MWB virtual desktop
/// coordinates (0..65535 in both axes).
///
/// All coordinate mapping uses Quartz (top-left origin) convention,
/// which is what CGEvent uses and matches the MWB protocol's origin.
///
/// Hot-path values are cached and invalidated on display configuration changes.
enum ScreenInfo {

    // MARK: - Cache

    private nonisolated(unsafe) static var _cachedVirtualDesktopBounds: CGRect?
    private nonisolated(unsafe) static var _cachedMainScreenBounds: CGRect?

    static func invalidateCache() {
        _cachedVirtualDesktopBounds = nil
        _cachedMainScreenBounds = nil
    }

    // MARK: - Main screen

    /// Main display bounds in Quartz coordinates (top-left origin).
    static var mainScreenBounds: CGRect {
        if let cached = _cachedMainScreenBounds { return cached }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        _cachedMainScreenBounds = bounds
        return bounds
    }

    /// Main screen pixel width (Quartz coordinates).
    static var mainScreenWidth: CGFloat {
        mainScreenBounds.width
    }

    /// Main screen pixel height (Quartz coordinates).
    static var mainScreenHeight: CGFloat {
        mainScreenBounds.height
    }

    /// Main screen dimensions as UInt16, suitable for MWB identity packets.
    static var mainScreenSizeUInt16: (width: UInt16, height: UInt16) {
        (
            width: UInt16(truncatingIfNeeded: Int(mainScreenWidth)),
            height: UInt16(truncatingIfNeeded: Int(mainScreenHeight))
        )
    }

    // MARK: - Virtual desktop (all screens combined)

    /// The union of all screen frames in Quartz coordinates.
    static var virtualDesktopBounds: CGRect {
        if let cached = _cachedVirtualDesktopBounds { return cached }
        let screens = NSScreen.screens
        guard let first = screens.first else {
            return mainScreenBounds
        }

        // NSScreen.frame uses AppKit (bottom-left) coordinates.
        // Convert the first frame's origin to Quartz by flipping Y.
        let screenHeight = first.frame.height
        var result = CGRect.zero
        result.origin.x = first.frame.origin.x
        result.origin.y = screenHeight - first.frame.origin.y - first.frame.height
        result.size.width = first.frame.width
        result.size.height = first.frame.height

        for screen in screens.dropFirst() {
            let quartzRect = nsScreenToQuartz(screen.frame, primaryHeight: screenHeight)
            result = result.union(quartzRect)
        }

        _cachedVirtualDesktopBounds = result
        return result
    }

    /// Total virtual desktop pixel width across all screens.
    static var virtualDesktopWidth: CGFloat {
        virtualDesktopBounds.width
    }

    /// Total virtual desktop pixel height across all screens.
    static var virtualDesktopHeight: CGFloat {
        virtualDesktopBounds.height
    }

    // MARK: - Coordinate mapping

    /// Maps a Quartz screen point to MWB virtual desktop coordinates (0..65535).
    ///
    /// Both Quartz and MWB use top-left origin, so no Y-flip is needed.
    /// The mapping is relative to the main screen bounds (same as MWB's behavior
    /// for a single-machine setup).
    static func screenToVirtual(_ point: CGPoint) -> (x: Int32, y: Int32) {
        let bounds = mainScreenBounds
        let max = CGFloat(MWBConstants.virtualDesktopMax)

        let virtualX = Int32(((point.x - bounds.minX) / bounds.width) * max)
        let virtualY = Int32(((point.y - bounds.minY) / bounds.height) * max)

        // Clamp to valid MWB range.
        let clampedX = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, virtualX))
        let clampedY = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, virtualY))

        return (clampedX, clampedY)
    }

    /// Maps MWB virtual desktop coordinates (0..65535) to a Quartz screen point.
    ///
    /// The mapping is relative to the main screen bounds.
    static func virtualToScreen(x: Int32, y: Int32) -> CGPoint {
        let bounds = mainScreenBounds
        let max = CGFloat(MWBConstants.virtualDesktopMax)

        let screenX = bounds.minX + (CGFloat(x) / max) * bounds.width
        let screenY = bounds.minY + (CGFloat(y) / max) * bounds.height

        return CGPoint(x: screenX, y: screenY)
    }

    // MARK: - Screen list

    /// All NSScreen instances currently attached.
    static var screens: [NSScreen] {
        NSScreen.screens
    }

    /// Number of attached displays.
    static var screenCount: Int {
        NSScreen.screens.count
    }

    // MARK: - Private helpers

    /// Converts an NSScreen frame (AppKit bottom-left origin) to Quartz
    /// (top-left origin) using the primary screen's height for the flip.
    private static func nsScreenToQuartz(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
