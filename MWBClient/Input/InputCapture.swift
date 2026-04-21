import AppKit
import CoreGraphics
import os.log

/// Captures local mouse and keyboard events via CGEventTap and converts them
/// to MWB protocol format for forwarding to a remote machine.
///
/// Uses a class (not actor) because CGEventTap callbacks are C function pointers
/// that require a global bridging context.
///
/// Thread safety: All public API is called from the main thread. The event tap
/// callback runs on the main run loop (CFMachPort / RunLoopSource). The
/// `crossingActive` flag is a simple Bool read in the callback -- it must only
/// be set from the main thread to avoid races.
final class InputCapture {

    // MARK: - Types

    /// Callback invoked with a ``MouseData`` packet whenever a local mouse event
    /// is captured (including during crossing, before suppression).
    typealias MouseCallback = @Sendable (MouseData) -> Void

    /// Callback for mouse position tracking (e.g. edge detection). Includes
    /// the screen-space point alongside the protocol ``MouseData``.
    typealias MousePositionCallback = @Sendable (MouseData, CGPoint) -> Void

    /// Callback invoked with a ``KeyboardData`` packet whenever a local keyboard
    /// event is captured (including during crossing, before suppression).
    typealias KeyboardCallback = @Sendable (KeyboardData) -> Void

    // MARK: - Public state

    /// When true, captured events are suppressed (not delivered to the system)
    /// and only forwarded via callbacks.
    var crossingActive = false

    /// Whether the event tap is currently running.
    private(set) var isRunning = false

    // MARK: - Callbacks

    var onMouseEvent: MouseCallback?
    var onMousePosition: MousePositionCallback?
    var onKeyboardEvent: KeyboardCallback?

    /// Called when accessibility permission is revoked while the event tap is running.
    var onPermissionRevoked: (@Sendable () -> Void)?

    // MARK: - Private state

    /// The CFMachPort for the event tap. Exposed as ``fileprivate`` so the
    /// file-level C callback can re-enable the tap after a timeout.
    private(set) fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Screen bounds in Quartz (top-left origin) coordinates. Cached on start().
    private var screenBounds: CGRect = CGDisplayBounds(CGMainDisplayID())

    /// Timer for periodic accessibility permission checks.
    private var permissionCheckTimer: DispatchSourceTimer?

    // MARK: - Accessibility permission

    /// Returns whether the app has been granted Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission by showing a
    /// system dialog that opens System Preferences.
    static func requestAccessibilityPermission() {
        // Use the raw CFString value to avoid Swift 6 concurrency warning
        // on the global kAXTrustedCheckOptionPrompt var.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    /// Creates the event tap and installs it on the current run loop.
    ///
    /// Must be called from the main thread. The tap listens at
    /// `kCGHIDEventTap` for mouse move, button, scroll, and keyboard events.
    ///
    /// - Returns: `true` if the tap was created and installed successfully.
    func start() -> Bool {
        guard !isRunning else { return true }

        guard InputCapture.hasAccessibilityPermission() else {
            Logger.input.warning("Accessibility permission not granted, requesting")
            InputCapture.requestAccessibilityPermission()
            return false
        }

        Logger.input.info("Starting input capture")

        // Cache the main display bounds for coordinate mapping.
        screenBounds = CGDisplayBounds(CGMainDisplayID())

        // Store self in the global bridge so the C callback can reach it.
        inputCaptureBridge = self

        // Build the event mask: mouse move, all button clicks, scroll, keyboard.
        // Broken into sub-expressions to avoid Swift type-checker timeout.
        let mouseMovedBit = 1 << CGEventType.mouseMoved.rawValue
        let leftDownBit = 1 << CGEventType.leftMouseDown.rawValue
        let leftUpBit = 1 << CGEventType.leftMouseUp.rawValue
        let rightDownBit = 1 << CGEventType.rightMouseDown.rawValue
        let rightUpBit = 1 << CGEventType.rightMouseUp.rawValue
        let otherDownBit = 1 << CGEventType.otherMouseDown.rawValue
        let otherUpBit = 1 << CGEventType.otherMouseUp.rawValue
        let scrollBit = 1 << CGEventType.scrollWheel.rawValue
        let keyDownBit = 1 << CGEventType.keyDown.rawValue
        let keyUpBit = 1 << CGEventType.keyUp.rawValue
        let flagsChangedBit = 1 << CGEventType.flagsChanged.rawValue

        let eventMask = CGEventMask(
            mouseMovedBit | leftDownBit | leftUpBit
            | rightDownBit | rightUpBit
            | otherDownBit | otherUpBit
            | scrollBit
            | keyDownBit | keyUpBit | flagsChangedBit
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            inputCaptureBridge = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true

        startPermissionMonitor()

        return true
    }

    /// Disables and removes the event tap from the run loop.
    func stop() {
        guard isRunning else { return }
        Logger.input.info("Stopping input capture")

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        inputCaptureBridge = nil
        isRunning = false

        permissionCheckTimer?.cancel()
        permissionCheckTimer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Permission Monitoring

    /// Starts a periodic timer that checks if accessibility permission has been revoked.
    /// If revoked mid-session, stops the event tap and notifies via ``onPermissionRevoked``.
    private func startPermissionMonitor() {
        permissionCheckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            if !Self.hasAccessibilityPermission() {
                Logger.input.error("Accessibility permission revoked mid-session, stopping capture")
                self.stop()
                self.onPermissionRevoked?()
            }
        }
        timer.resume()
        permissionCheckTimer = timer
    }

    // MARK: - Coordinate mapping (screen -> MWB virtual desktop)

    /// Maps a Quartz screen point to MWB virtual desktop coordinates (0-65535).
    ///
    /// Both Quartz and MWB use top-left origin, so no Y-flip is needed.
    private func mapScreenToVirtual(_ point: CGPoint) -> (x: Int32, y: Int32) {
        let virtualMax = CGFloat(MWBConstants.virtualDesktopMax)
        let bounds = screenBounds

        let virtualX = Int32(((point.x - bounds.minX) / bounds.width) * virtualMax)
        let virtualY = Int32(((point.y - bounds.minY) / bounds.height) * virtualMax)

        // Clamp to valid range. Use Swift.max/min to avoid ambiguity with CGFloat.
        let clampedX = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, virtualX))
        let clampedY = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, virtualY))

        return (clampedX, clampedY)
    }

    // MARK: - Event dispatch

    /// Called from the C callback for every captured mouse event.
    ///
    /// Extracts position, button state, and scroll delta from the CGEvent,
    /// converts to MWB ``MouseData``, and forwards to `onMouseEvent`.
    /// Returns nil (suppress) when `crossingActive` is true.
    fileprivate func handleMouseEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        let location = event.location
        let (vx, vy) = mapScreenToVirtual(location)

        let mouseData: MouseData
        let wmMessage: WMMouseMessage

        switch type {
        case .mouseMoved:
            wmMessage = .mouseMove
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .leftMouseDown:
            wmMessage = .lButtonDown
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .leftMouseUp:
            wmMessage = .lButtonUp
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .rightMouseDown:
            wmMessage = .rButtonDown
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .rightMouseUp:
            wmMessage = .rButtonUp
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .otherMouseDown:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            // Middle button = button 2 on macOS. MWB protocol only distinguishes
            // left, right, and middle, so map all "other" buttons to middle.
            wmMessage = .mButtonDown
            _ = buttonNumber // acknowledged
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            wmMessage = .mButtonUp
            _ = buttonNumber // acknowledged
            mouseData = MouseData(x: vx, y: vy, wheelDelta: 0, dwFlags: wmMessage.rawValue)

        case .scrollWheel:
            // kCGScrollWheelEventDelta1 = 11, kCGScrollWheelEventDelta2 = 12
            // These constants have been removed from the Swift overlay but
            // still work with raw CGEventField values.
            let fieldDelta1 = CGEventField(rawValue: 11)!
            let fieldDelta2 = CGEventField(rawValue: 12)!
            let delta1 = event.getIntegerValueField(fieldDelta1)
            let delta2 = event.getIntegerValueField(fieldDelta2)
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

            // Determine scroll direction and convert to MWB WHEEL_DELTA (120 per notch).
            if delta2 != 0 && delta1 == 0 {
                // Horizontal scroll.
                let mwbDelta: Int32 = isContinuous
                    ? Int32(CGFloat(delta2) * 120.0 / 3.0)
                    : Int32(delta2 * 120)
                wmMessage = .mouseHWheel
                mouseData = MouseData(x: vx, y: vy, wheelDelta: mwbDelta, dwFlags: wmMessage.rawValue)
            } else {
                // Vertical scroll. macOS positive = scroll up, MWB positive = scroll up.
                let mwbDelta: Int32 = isContinuous
                    ? Int32(CGFloat(delta1) * 120.0 / 3.0)
                    : Int32(delta1 * 120)
                wmMessage = .mouseWheel
                mouseData = MouseData(x: vx, y: vy, wheelDelta: mwbDelta, dwFlags: wmMessage.rawValue)
            }

        default:
            // Unknown mouse event type; pass through without forwarding.
            return Unmanaged.passUnretained(event)
        }

        // Forward to callback regardless of suppression state.
        onMouseEvent?(mouseData)
        onMousePosition?(mouseData, location)

        // Suppress the event when crossing is active.
        if crossingActive {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Called from the C callback for every captured keyboard event.
    ///
    /// Extracts keycode, up/down state, and modifier flags from the CGEvent,
    /// converts to MWB ``KeyboardData`` via ``KeyCodeMapper``, and forwards
    /// to `onKeyboardEvent`. Returns nil (suppress) when `crossingActive` is true.
    fileprivate func handleKeyboardEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        let macKeycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        guard let vkCode = KeyCodeMapper.macOSToVK(macOSKeycode: macKeycode) else {
            // Unmapped key; pass through without forwarding.
            return Unmanaged.passUnretained(event)
        }

        var flags: UInt32 = 0

        // Check for extended key flag (right-side modifiers on Windows).
        let isRightModifier = isRightSideModifierKey(macKeycode: macKeycode)
        if isRightModifier {
            flags |= LLKHFFlag.extended.rawValue
        }

        // Determine key up/down state.
        switch type {
        case .keyUp:
            flags |= LLKHFFlag.up.rawValue
        case .keyDown:
            // Already key down; up flag stays 0.
            break
        case .flagsChanged:
            // Modifier change: use the key state to determine up/down.
            // CGEventGetIntegerValueField(.keyboardEventKeycode) gives the modifier keycode.
            // For flagsChanged, we check the current modifier state to determine direction.
            if isModifierReleased(event: event, keycode: macKeycode) {
                flags |= LLKHFFlag.up.rawValue
            }
        default:
            break
        }

        // Build scan code from macOS keycode (they are already scancode-like on macOS).
        let scanCode = macKeycode

        let keyboardData = KeyboardData(vkCode: vkCode, scanCode: scanCode, flags: flags)

        // Forward to callback regardless of suppression state.
        onKeyboardEvent?(keyboardData)

        // Suppress the event when crossing is active.
        if crossingActive {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier key helpers

    /// macOS keycodes for right-side modifiers that map to Windows extended keys.
    private static let rightModifierKeycodes: Set<UInt16> = [
        0x3C, // Right Shift
        0x3E, // Right Control
        0x3D, // Right Option (Alt)
        0x36, // Right Command (Win)
    ]

    /// Returns true if the given macOS keycode is a right-side modifier key.
    private func isRightSideModifierKey(macKeycode: UInt16) -> Bool {
        Self.rightModifierKeycodes.contains(macKeycode)
    }

    /// Determines whether a modifier key was released in a flagsChanged event.
    ///
    /// Checks the modifier flags bitmask: if the corresponding modifier bit
    /// is NOT set, the key was released.
    private func isModifierReleased(event: CGEvent, keycode: UInt16) -> Bool {
        let flags = event.flags
        switch keycode {
        case 0x38, 0x3C: // Left Shift, Right Shift
            return !flags.contains(.maskShift)
        case 0x3B, 0x3E: // Left Control, Right Control
            return !flags.contains(.maskControl)
        case 0x3A, 0x3D: // Left Option, Right Option
            return !flags.contains(.maskAlternate)
        case 0x37, 0x36: // Left Command, Right Command
            return !flags.contains(.maskCommand)
        case 0x39: // Caps Lock
            // Caps Lock toggles; treat as key down (press) for simplicity.
            return false
        default:
            // Non-modifier key in flagsChanged; treat as key down.
            return false
        }
    }
}

// MARK: - C callback bridge

/// Global reference to the active InputCapture instance, used by the C
/// callback function pointer. This is the standard pattern for bridging
/// CGEventTap callbacks into Swift.
///
/// - Warning: Only one InputCapture instance should be active at a time.
///           The `start()` / `stop()` methods manage this reference.
///
/// Thread safety: All access occurs on the main thread / main run loop.
/// - `start()` and `stop()` are main-thread-only
/// - The CGEventTap callback fires on the main run loop
nonisolated(unsafe) private weak var inputCaptureBridge: InputCapture?

/// C callback for CGEventTapCreate. Routes events to the current
/// ``InputCapture`` instance based on `inputCaptureBridge`.
private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Let system-defined events (tap enable/disable, etc.) pass through.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Re-enable the tap if it was disabled by timeout.
        if type == .tapDisabledByTimeout {
            if let tap = inputCaptureBridge?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let capture = inputCaptureBridge else {
        return Unmanaged.passUnretained(event)
    }

    // Route to the appropriate handler based on event type.
    switch type {
    case .mouseMoved,
         .leftMouseDown, .leftMouseUp,
         .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp,
         .scrollWheel:
        return capture.handleMouseEvent(event, type: type)

    case .keyDown, .keyUp, .flagsChanged:
        return capture.handleKeyboardEvent(event, type: type)

    default:
        return Unmanaged.passUnretained(event)
    }
}
