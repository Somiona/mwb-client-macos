import AppKit
import CoreGraphics

/// Injects mouse and keyboard events into macOS via CGEvent.
///
/// Maps MWB virtual desktop coordinates (0-65535) to local NSScreen
/// coordinates and posts events at the HID event tap level.
///
/// Usage is expected from a single callback path (NetworkManager / ServerListener
/// receive pump), so no internal synchronization is required.
final class InputInjection {

    // MARK: - State

    /// Last mapped screen position, tracked for delta calculation.
    private var lastPosition: CGPoint = .zero

    /// Whether we have ever received a mouse event. The first event
    /// after a crossing should warp the cursor to the target position
    /// rather than posting a relative delta.
    private var needsWarp = true

    // MARK: - Coordinate mapping

    /// Returns the frame of the main screen in global (Cocoa) coordinates.
    private var mainScreenFrame: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Maps an MWB virtual desktop coordinate (0-65535) to a local screen point.
    ///
    /// MWB uses a coordinate system where (0,0) is the top-left and
    /// 65535 is the maximum for both axes. macOS NSScreen uses bottom-left
    /// origin, so the Y axis is flipped.
    private func mapVirtualToScreen(x: Int32, y: Int32) -> CGPoint {
        let frame = mainScreenFrame
        let max = CGFloat(MWBConstants.virtualDesktopMax)

        let screenX = frame.minX + (CGFloat(x) / max) * frame.width
        // Flip Y: MWB 0 = top, NSScreen maxY = top
        let screenY = frame.maxY - (CGFloat(y) / max) * frame.height

        return CGPoint(x: screenX, y: screenY)
    }

    // MARK: - Cursor warping

    /// Moves the cursor to an absolute position without generating events.
    ///
    /// Should be called once on the first mouse packet after a crossing
    /// to snap the cursor to the correct entry position.
    func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        lastPosition = point
        needsWarp = false
    }

    // MARK: - Mouse injection

    /// Injects a mouse event based on MWB MouseData.
    ///
    /// Handles movement, button clicks, and scroll wheel events.
    /// On the first packet after a crossing, the cursor is warped to
    /// the target position instead of posting a relative move.
    func injectMouse(_ data: MouseData) {
        guard let message = data.wmMessage else { return }

        let target = mapVirtualToScreen(x: data.x, y: data.y)

        switch message {
        case .mouseMove:
            handleMouseMove(to: target)
        case .lButtonDown:
            postMouseButtonEvent(.leftMouseDown, at: target)
        case .lButtonUp:
            postMouseButtonEvent(.leftMouseUp, at: target)
        case .rButtonDown:
            postMouseButtonEvent(.rightMouseDown, at: target)
        case .rButtonUp:
            postMouseButtonEvent(.rightMouseUp, at: target)
        case .mButtonDown:
            postMouseButtonEvent(.otherMouseDown, at: target, button: .center)
        case .mButtonUp:
            postMouseButtonEvent(.otherMouseUp, at: target, button: .center)
        case .mouseWheel:
            handleScrollWheel(delta: data.wheelDelta, at: target, horizontal: false)
        case .mouseHWheel:
            handleScrollWheel(delta: data.wheelDelta, at: target, horizontal: true)
        }
    }

    // MARK: - Mouse helpers

    private func handleMouseMove(to target: CGPoint) {
        if needsWarp {
            warpCursor(to: target)
            return
        }

        let dx = target.x - lastPosition.x
        let dy = target.y - lastPosition.y

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        lastPosition = target
    }

    private func postMouseButtonEvent(
        _ type: CGEventType,
        at location: CGPoint,
        button: CGMouseButton = .left
    ) {
        // Warp to target if this is the first event after crossing
        if needsWarp {
            warpCursor(to: location)
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else { return }

        // For middle button, set the mouse button number
        if button == .center {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        }

        event.post(tap: .cghidEventTap)
        lastPosition = location
    }

    private func handleScrollWheel(delta: Int32, at location: CGPoint, horizontal: Bool) {
        if needsWarp {
            warpCursor(to: location)
        }

        // MWB sends +/-120 per notch (WHEEL_DELTA). Convert to pixel scroll.
        // macOS convention: positive = scroll up / scroll left.
        // WHEEL_DELTA positive in MWB = scroll away from user = scroll up (negative Y in macOS).
        let pixelDelta = Int32(CGFloat(delta) / 120.0 * 3.0)

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: horizontal ? pixelDelta : -pixelDelta,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard injection

    /// Injects a keyboard event based on MWB KeyboardData.
    ///
    /// Maps the Windows VK code to a macOS keycode via ``KeyCodeMapper``
    /// and posts a key down or key up event. Unmapped VK codes are silently
    /// ignored.
    func injectKeyboard(_ data: KeyboardData) {
        guard let macOSKeycode = KeyCodeMapper.vkToMacOS(vkCode: data.vkCode) else {
            return
        }

        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: macOSKeycode,
            keyDown: !data.isKeyUp
        ) else { return }

        // Set the keycode explicitly (redundant with virtualKey but ensures correctness)
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(macOSKeycode))

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Reset

    /// Resets the injection state.
    ///
    /// Should be called when a crossing ends or the connection is lost,
    /// so the next incoming event will trigger a cursor warp.
    func reset() {
        lastPosition = .zero
        needsWarp = true
    }
}
