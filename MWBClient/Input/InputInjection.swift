import AppKit
import CoreGraphics
import os.log

/// Shared source for all MWB-injected events. A persistent source gives
/// posted events a nonzero event number and source context, so the macOS
/// gesture stack can bind them into event streams; the combined-session
/// state also synthesizes click counts (double-click) across injections.
enum MWBEventSource {
    // CGEventSource is not Sendable; it is created once and only read here,
    // so unchecked sharing is safe.
    nonisolated(unsafe) static let shared = CGEventSource(stateID: .combinedSessionState)
}

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

    /// Currently held mouse buttons, used to type move events as drags.
    private(set) var leftDown = false
    private(set) var rightDown = false
    private(set) var otherDown = false

    /// PowerToys MOVE_MOUSE_RELATIVE threshold. When |X| and |Y| both
    /// exceed this value, coordinates represent a relative pixel offset.
    private static let moveMouseRelative: Int32 = 100_000

    // MARK: - Click state synthesis

    /// Per-button click-chain state (deskflow/Synergy approach). macOS does
    /// not compute click counts for injected events — apps read
    /// `kCGMouseEventClickState` straight from each event — so we track press
    /// timing and position ourselves.
    private struct ClickTracker {
        var count: Int64 = 1
        var lastPress: ContinuousClock.Instant?
        /// Position of the first (single) click in the current chain.
        var anchor: CGPoint = .zero
    }

    private var clickTrackers: [CGMouseButton: ClickTracker] = [:]

    /// Distance (points) within which two presses extend the same click
    /// chain. Tolerant of hand jitter forwarded by the sender (deskflow uses
    /// sqrt(2); the extra headroom keeps remote double-clicks reliable).
    private static let clickChainDistance: CGFloat = 8.0

    /// Advances the click chain for a button press and returns the new click
    /// state (1 = single, 2 = double, 3 = triple, ...).
    private func advanceClickState(button: CGMouseButton, at position: CGPoint) -> Int64 {
        let now = ContinuousClock().now
        var tracker = clickTrackers[button] ?? ClickTracker()

        let interval = Duration.seconds(NSEvent.doubleClickInterval)
        if let lastPress = tracker.lastPress,
           lastPress.duration(to: now) <= interval,
           hypot(position.x - tracker.anchor.x, position.y - tracker.anchor.y) <= Self.clickChainDistance {
            tracker.count += 1
        } else {
            tracker.count = 1
            tracker.anchor = position
        }
        tracker.lastPress = now
        clickTrackers[button] = tracker
        return tracker.count
    }

    /// The click state a release event must carry: the same value as its
    /// matching press (mouse-down and mouse-up pairs share the click state).
    func currentClickCount(for button: CGMouseButton) -> Int64 {
        clickTrackers[button]?.count ?? 1
    }

    // MARK: - Keyboard state

    /// macOS keycodes for the modifier keys handled via `.flagsChanged` synthesis.
    static let modifierKeycodes: Set<UInt16> = [
        0x38, 0x3C,  // Left/Right Shift
        0x3B, 0x3E,  // Left/Right Control
        0x3A, 0x3D,  // Left/Right Option
        0x37, 0x36,  // Left/Right Command
    ]

    /// macOS keycode for Caps Lock.
    static let capsLockKeycode: UInt16 = 0x39

    /// macOS numeric-keypad keycodes. Hardware keypad events always carry
    /// .maskNumericPad, and apps such as Terminal ignore synthetic keypad
    /// key events without it, so injected keypad key events must set the flag.
    static let keypadKeycodes: Set<UInt16> = [
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E,
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
    ]

    /// Modifier keycodes currently held down by injected events.
    private(set) var heldModifiers: Set<UInt16> = []

    /// Local Caps Lock state synthesized from remote toggles. Not synced with
    /// the remote machine (matches the reference implementation).
    private var capsLockOn = false

    // MARK: - Coordinate mapping

    /// Returns the main display bounds in Quartz (top-left origin) coordinates.
    /// CGEvent uses Quartz coordinates, not NSScreen (bottom-left origin).
    var screenBoundsProvider: () -> CGRect = { NSScreen.fullDesktopBounds }

    private var mainScreenBounds: CGRect {
        screenBoundsProvider()
    }

    /// Maps an MWB virtual desktop coordinate (0-65535) to a Quartz screen point.
    ///
    /// Both MWB and Quartz use top-left origin, so no Y-flip is needed.
    func mapVirtualToScreen(x: Int32, y: Int32) -> CGPoint {
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
            mwbWarning(MWBLog.input, "Inject mouse: unknown WM message")
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

        mwbDebug(MWBLog.input, "Inject mouse: \(String(describing: message)) at (\(data.x), \(data.y))")

        let target = mapVirtualToScreen(x: data.x, y: data.y)

        switch message {
        case .mouseMove:
            handleMouseMove(to: target)
        case .lButtonDown:
            if leftDown {
                // The paired mouse-up was lost (machine switch, network gap,
                // or the sender swallowing it); resync before a new stream.
                postMouseButtonEvent(.leftMouseUp, at: target)
            }
            leftDown = true
            postMouseButtonEvent(.leftMouseDown, at: target)
        case .lButtonUp:
            leftDown = false
            postMouseButtonEvent(.leftMouseUp, at: target)
        case .rButtonDown:
            if rightDown {
                postMouseButtonEvent(.rightMouseUp, at: target, button: .right)
            }
            rightDown = true
            postMouseButtonEvent(.rightMouseDown, at: target, button: .right)
        case .rButtonUp:
            rightDown = false
            postMouseButtonEvent(.rightMouseUp, at: target, button: .right)
        case .mButtonDown:
            if otherDown {
                postMouseButtonEvent(.otherMouseUp, at: target, button: .center)
            }
            otherDown = true
            postMouseButtonEvent(.otherMouseDown, at: target, button: .center)
        case .mButtonUp:
            otherDown = false
            postMouseButtonEvent(.otherMouseUp, at: target, button: .center)
        case .mouseWheel:
            handleScrollWheel(delta: data.wheelDelta, at: target, horizontal: false)
        case .mouseHWheel:
            handleScrollWheel(delta: data.wheelDelta, at: target, horizontal: true)
        }
    }

    // MARK: - Mouse helpers

    /// The CGEventType for a move event given the held buttons. macOS only
    /// delivers drags to apps when the event is typed as a drag; a plain
    /// `.mouseMoved` while a button is held is ignored by most apps.
    static func moveEventType(left: Bool, right: Bool, other: Bool) -> CGEventType {
        if left { return .leftMouseDragged }
        if right { return .rightMouseDragged }
        if other { return .otherMouseDragged }
        return .mouseMoved
    }

    private static func button(for type: CGEventType) -> CGMouseButton {
        switch type {
        case .rightMouseDragged: return .right
        case .otherMouseDragged: return .center
        default: return .left
        }
    }

    private func handleMouseMove(to target: CGPoint) {
        if needsWarp {
            warpCursor(to: target)
            return
        }

        let dx = target.x - lastPosition.x
        let dy = target.y - lastPosition.y

        let type = Self.moveEventType(left: leftDown, right: rightDown, other: otherDown)

        guard let event = CGEvent(
            mouseEventSource: MWBEventSource.shared,
            mouseType: type,
            mouseCursorPosition: target,
            mouseButton: Self.button(for: type)
        ) else {
            mwbError(MWBLog.input, "Failed to create mouse move CGEvent")
            return
        }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        setClickStateIfNeeded(event, type: type)
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

        let type = Self.moveEventType(left: leftDown, right: rightDown, other: otherDown)

        guard let event = CGEvent(
            mouseEventSource: MWBEventSource.shared,
            mouseType: type,
            mouseCursorPosition: target,
            mouseButton: Self.button(for: type)
        ) else {
            mwbError(MWBLog.input, "Failed to create relative mouse CGEvent")
            return
        }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        setClickStateIfNeeded(event, type: type)
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
            mouseEventSource: MWBEventSource.shared,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            mwbError(MWBLog.input, "Failed to create mouse button CGEvent")
            return
        }

        // For middle button, set the mouse button number
        if button == .center {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        }

        // Advance the chain on press; the paired release carries the same state.
        let isPress = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let clickState = isPress
            ? advanceClickState(button: button, at: location)
            : currentClickCount(for: button)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)

        event.post(tap: .cghidEventTap)
        lastPosition = location
    }

    /// Drag events carry the click state of the held button (e.g. word
    /// selection drags after a double-click); plain moves keep the default.
    private func setClickStateIfNeeded(_ event: CGEvent, type: CGEventType) {
        guard type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: currentClickCount(for: Self.button(for: type)))
    }

    /// Converts a raw MWB wheel delta (multiples of 120) to macOS pixel scroll
    /// units, optionally inverting the direction.
    static func scrollPixels(delta: Int32, invert: Bool) -> Int32 {
        var pixels = Int32((CGFloat(delta) / 120.0) * 3.0)
        if invert { pixels = -pixels }
        return pixels
    }

    private func handleScrollWheel(delta: Int32, at location: CGPoint, horizontal: Bool) {
        if needsWarp {
            warpCursor(to: location)
        }

        // MWB sends +/-120 per notch (WHEEL_DELTA). Convert to pixel scroll.
        // macOS convention: positive = scroll up / scroll left.
        // WHEEL_DELTA positive in MWB = scroll away from user = scroll up (negative Y in macOS).
        let pixelDelta = Self.scrollPixels(delta: delta, invert: CachedSettings.invertRemoteScroll)

        guard let event = CGEvent(
            scrollWheelEvent2Source: MWBEventSource.shared,
            units: .pixel,
            wheelCount: 1,
            wheel1: horizontal ? pixelDelta : -pixelDelta,
            wheel2: 0,
            wheel3: 0
        ) else {
            mwbError(MWBLog.input, "Failed to create scroll wheel CGEvent")
            return
        }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard injection

    /// Computes the full CGEventFlags for a modifier state, matching how macOS
    /// reports flags on real hardware events. Never synthesizes Fn or
    /// numeric-pad state; keypad *key* events add .maskNumericPad on top via
    /// ``keyEventFlags(keycode:held:capsLockOn:)``.
    static func modifierFlags(held: Set<UInt16>, capsLockOn: Bool) -> CGEventFlags {
        var flags: CGEventFlags = []
        if held.contains(0x38) || held.contains(0x3C) { flags.insert(.maskShift) }
        if held.contains(0x3B) || held.contains(0x3E) { flags.insert(.maskControl) }
        if held.contains(0x3A) || held.contains(0x3D) { flags.insert(.maskAlternate) }
        if held.contains(0x37) || held.contains(0x36) { flags.insert(.maskCommand) }
        if capsLockOn { flags.insert(.maskAlphaShift) }
        return flags
    }

    /// Full CGEventFlags for an injected key event: the synthesized modifier
    /// state plus .maskNumericPad for keypad keycodes (matches hardware).
    static func keyEventFlags(keycode: UInt16, held: Set<UInt16>, capsLockOn: Bool) -> CGEventFlags {
        var flags = modifierFlags(held: held, capsLockOn: capsLockOn)
        if keypadKeycodes.contains(keycode) { flags.insert(.maskNumericPad) }
        return flags
    }

    /// The full modifier flags for the currently synthesized state.
    var currentModifierFlags: CGEventFlags {
        Self.modifierFlags(held: heldModifiers, capsLockOn: capsLockOn)
    }

    /// Injects a keyboard event based on MWB KeyboardData.
    ///
    /// Maps the Windows VK code to a macOS keycode via ``KeyCodeMapper`` and
    /// posts either a key event (carrying the full modifier state in its flags,
    /// so shortcuts like Ctrl+C resolve in the target app) or a well-formed
    /// `.flagsChanged` event for modifier keys. Unmapped VK codes are silently
    /// ignored.
    ///
    /// - Parameter swapOptionCommand: When true, Option and Command keycodes
    ///   are swapped after the table lookup (for keyboards laid out
    ///   Ctrl-Win-Alt instead of Ctrl-Opt-Cmd).
    func injectKeyboard(_ data: KeyboardData, swapOptionCommand: Bool = false) {
        guard var keycode = KeyCodeMapper.vkToMacOS(vkCode: data.vkCode, extended: data.isExtended) else {
            mwbDebug(MWBLog.input, "Inject keyboard: unmapped VK code \(data.vkCode)")
            return
        }

        if swapOptionCommand {
            keycode = KeyCodeMapper.swappedModifierKeycode(keycode)
        }

        if keycode == Self.capsLockKeycode {
            // Caps Lock behaves as a toggle: each key down flips the lock
            // state; key ups are ignored (matches hardware semantics).
            guard !data.isKeyUp else { return }
            capsLockOn.toggle()
            postFlagsChanged(keycode: keycode, keyDown: true)
            return
        }

        if Self.modifierKeycodes.contains(keycode) {
            let keyDown = !data.isKeyUp
            if keyDown {
                heldModifiers.insert(keycode)
            } else {
                heldModifiers.remove(keycode)
            }
            postFlagsChanged(keycode: keycode, keyDown: keyDown)
            return
        }

        guard let event = CGEvent(
            keyboardEventSource: MWBEventSource.shared,
            virtualKey: keycode,
            keyDown: !data.isKeyUp
        ) else {
            mwbError(MWBLog.input, "Failed to create keyboard CGEvent for keycode \(keycode)")
            return
        }

        // Set the keycode explicitly (redundant with virtualKey but ensures correctness)
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keycode))

        event.flags = Self.keyEventFlags(keycode: keycode, held: heldModifiers, capsLockOn: capsLockOn)
        event.post(tap: .cghidEventTap)
    }

    /// Posts a well-formed `.flagsChanged` event for a modifier transition.
    ///
    /// `heldModifiers` / `capsLockOn` must already reflect the post-transition
    /// state so `event.flags` matches what macOS would generate for the same
    /// physical key press. Posting an explicit `.flagsChanged` event with
    /// explicit flags (instead of a bare keyDown on a modifier keycode) keeps
    /// the system modifier state consistent.
    private func postFlagsChanged(keycode: UInt16, keyDown: Bool) {
        let held = heldModifiers
            .sorted()
            .map { String(format: "0x%02X", $0) }
            .joined(separator: ",")
        mwbDebug(
            MWBLog.input,
            "Modifier transition: keycode \(String(format: "0x%02X", keycode)) \(keyDown ? "down" : "up"), held=[\(held)], capsLock=\(capsLockOn)")

        guard let event = CGEvent(
            keyboardEventSource: MWBEventSource.shared,
            virtualKey: keycode,
            keyDown: keyDown
        ) else {
            mwbError(MWBLog.input, "Failed to create flagsChanged CGEvent for keycode \(keycode)")
            return
        }

        event.type = .flagsChanged
        event.flags = currentModifierFlags
        event.post(tap: .cghidEventTap)
    }

    /// Releases every modifier currently held down by injected events.
    ///
    /// Mirrors the reference `ReleaseAllKeys()`: called when this machine
    /// loses control (HideMouse path, crossing end, connection loss) so the
    /// local session is not left with stuck modifiers. Caps Lock state is
    /// intentionally preserved (hardware toggle semantics).
    func releaseAllKeys() {
        guard !heldModifiers.isEmpty else { return }
        mwbInfo(MWBLog.input, "Releasing \(heldModifiers.count) held modifier(s)")
        while let keycode = heldModifiers.first {
            heldModifiers.remove(keycode)
            postFlagsChanged(keycode: keycode, keyDown: false)
        }
    }

    /// Posts synthetic mouse-ups for every button this injector left held down.
    /// Mirrors ``releaseAllKeys()``: called when this machine loses control so
    /// the window server button state is not left stuck. The reference
    /// implementation never sends mouse-ups on machine switch (its
    /// `ReleaseAllKeys` is keyboard-only), so the receiver must self-release.
    func releaseAllMouseButtons() {
        if leftDown {
            postMouseButtonEvent(.leftMouseUp, at: lastPosition)
            leftDown = false
        }
        if rightDown {
            postMouseButtonEvent(.rightMouseUp, at: lastPosition)
            rightDown = false
        }
        if otherDown {
            postMouseButtonEvent(.otherMouseUp, at: lastPosition, button: .center)
            otherDown = false
        }
    }

    // MARK: - Reset

    /// Resets the injection state.
    ///
    /// Should be called when a crossing ends or the connection is lost,
    /// so the next incoming event will trigger a cursor warp.
    func reset() {
        releaseAllKeys()
        // Release buttons before clearing lastPosition: the synthetic ups
        // must carry the last injected position.
        releaseAllMouseButtons()
        lastPosition = .zero
        needsWarp = true
        clickTrackers.removeAll()
    }
}
