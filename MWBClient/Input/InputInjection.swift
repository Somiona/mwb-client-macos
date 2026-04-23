import AppKit
import CoreGraphics
import os.log

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

    /// PowerToys MOVE_MOUSE_RELATIVE threshold. When |X| and |Y| both
    /// exceed this value, coordinates represent a relative pixel offset.
    private static let moveMouseRelative: Int32 = 100_000

    // MARK: - Coordinate mapping

    /// Returns the main display bounds in Quartz (top-left origin) coordinates.
    /// CGEvent uses Quartz coordinates, not NSScreen (bottom-left origin).
    private var mainScreenBounds: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    /// Maps an MWB virtual desktop coordinate (0-65535) to a Quartz screen point.
    ///
    /// Both MWB and Quartz use top-left origin, so no Y-flip is needed.
    private func mapVirtualToScreen(x: Int32, y: Int32) -> CGPoint {
        let bounds = mainScreenBounds
        let max = CGFloat(MWBConstants.virtualDesktopMax)

        let screenX = bounds.minX + (CGFloat(x) / max) * bounds.width
        let screenY = bounds.minY + (CGFloat(y) / max) * bounds.height

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
        guard let message = data.wmMessage else {
            Logger.input.warning("Inject mouse: unknown WM message")
            return
        }

        // Detect relative mouse coordinates (PowerToys MoveMouseRelatively).
        // When |X| and |Y| both exceed the threshold, extract pixel deltas.
        if abs(data.x) >= Self.moveMouseRelative && abs(data.y) >= Self.moveMouseRelative {
            let dx = data.x >= 0 ? data.x - Self.moveMouseRelative : data.x + Self.moveMouseRelative
            let dy = data.y >= 0 ? data.y - Self.moveMouseRelative : data.y + Self.moveMouseRelative
            handleRelativeMove(dx: CGFloat(dx), dy: CGFloat(dy))
            return
        }

        Logger.input.debug("Inject mouse: \(String(describing: message)) at (\(data.x), \(data.y))")

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
        ) else {
            Logger.input.error("Failed to create mouse move CGEvent")
            return
        }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        lastPosition = target
    }

    private func handleRelativeMove(dx: CGFloat, dy: CGFloat) {
        // Get current cursor position for the event location
        let current = NSEvent.mouseLocation
        // Convert from AppKit (bottom-left) to Quartz (top-left) coordinates
        let screen_height = mainScreenBounds.height
        let location = CGPoint(x: current.x, y: screen_height - current.y)
        let target = CGPoint(x: location.x + dx, y: location.y + dy)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else {
            Logger.input.error("Failed to create relative mouse CGEvent")
            return
        }

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
        ) else {
            Logger.input.error("Failed to create mouse button CGEvent")
            return
        }

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
        ) else {
            Logger.input.error("Failed to create scroll wheel CGEvent")
            return
        }

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
            Logger.input.debug("Inject keyboard: unmapped VK code \(data.vkCode)")
            return
        }

        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: macOSKeycode,
            keyDown: !data.isKeyUp
        ) else {
            Logger.input.error("Failed to create keyboard CGEvent for keycode \(macOSKeycode)")
            return
        }

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
