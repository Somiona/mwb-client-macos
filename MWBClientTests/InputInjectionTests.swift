import ApplicationServices
import CoreGraphics
import XCTest
@testable import MWBClient

/// Verifies the pure logic of ``InputInjection``: drag-aware move typing,
/// modifier flag synthesis, Caps Lock toggle semantics, releaseAllKeys, the
/// Option/Command swap, and scroll inversion.
///
/// The tests assert synthesized state, not posted events, so they run without
/// the Accessibility permission.
final class InputInjectionTests: XCTestCase {

    // MARK: - Drag-aware move typing

    func testMoveEventTypeMapsDrags() {
        XCTAssertEqual(InputInjection.moveEventType(left: true, right: false, other: false), .leftMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: true, other: false), .rightMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: false, other: true), .otherMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: false, other: false), .mouseMoved)
        // Left button wins when several are held.
        XCTAssertEqual(InputInjection.moveEventType(left: true, right: true, other: true), .leftMouseDragged)
        XCTAssertEqual(InputInjection.moveEventType(left: false, right: true, other: true), .rightMouseDragged)
    }

    // MARK: - Modifier flag synthesis

    func testModifierFlagsAccumulate() {
        let none = InputInjection.modifierFlags(held: [], capsLockOn: false)
        XCTAssertTrue(none.isEmpty)

        let cmd = InputInjection.modifierFlags(held: [0x37], capsLockOn: false)
        XCTAssertTrue(cmd.contains(.maskCommand))
        XCTAssertFalse(cmd.contains(.maskControl))
        XCTAssertFalse(cmd.contains(.maskAlternate))

        let leftAndRightControl = InputInjection.modifierFlags(held: [0x3B, 0x3E], capsLockOn: false)
        XCTAssertTrue(leftAndRightControl.contains(.maskControl))
        XCTAssertFalse(leftAndRightControl.contains(.maskCommand))

        let all: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36]
        let everything = InputInjection.modifierFlags(held: all, capsLockOn: true)
        XCTAssertTrue(everything.contains(.maskShift))
        XCTAssertTrue(everything.contains(.maskControl))
        XCTAssertTrue(everything.contains(.maskAlternate))
        XCTAssertTrue(everything.contains(.maskCommand))
        XCTAssertTrue(everything.contains(.maskAlphaShift))
        // Fn / numeric pad state is never synthesized.
        XCTAssertFalse(everything.contains(.maskSecondaryFn))
        XCTAssertFalse(everything.contains(.maskNumericPad))
    }

    func testKeyEventFlagsAddNumericPadForKeypad() {
        // Keypad keycodes carry .maskNumericPad like real hardware events.
        let pad0 = InputInjection.keyEventFlags(keycode: 0x52, held: [], capsLockOn: false)
        XCTAssertTrue(pad0.contains(.maskNumericPad))
        // Non-keypad keys never do.
        let letterA = InputInjection.keyEventFlags(keycode: 0x00, held: [], capsLockOn: false)
        XCTAssertFalse(letterA.contains(.maskNumericPad))
        // Keypad state composes with held modifiers.
        let shifted = InputInjection.keyEventFlags(keycode: 0x45, held: [0x38], capsLockOn: false)
        XCTAssertTrue(shifted.contains(.maskShift))
        XCTAssertTrue(shifted.contains(.maskNumericPad))
    }

    func testHeldModifiersTrackInjection() {
        let injection = InputInjection()

        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL down
        XCTAssertEqual(injection.heldModifiers, [0x3B])
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskControl))

        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: LLKHFFlag.up.rawValue))
        XCTAssertTrue(injection.heldModifiers.isEmpty)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskControl))
    }

    func testCapsLockTogglesPerKeyDown() {
        let injection = InputInjection()
        let capsDown = KeyboardData(vkCode: 0x14, flags: 0)
        let capsUp = KeyboardData(vkCode: 0x14, flags: LLKHFFlag.up.rawValue)

        injection.injectKeyboard(capsDown)
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))

        // Key up must be ignored: the lock state only changes on key down.
        injection.injectKeyboard(capsUp)
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))

        // Second key down toggles the lock off.
        injection.injectKeyboard(capsDown)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskAlphaShift))
    }

    func testSwapOptionCommandRemapsModifiers() {
        let injection = InputInjection()
        let winDown = KeyboardData(vkCode: 0x5B, flags: 0)  // VK_LWIN

        injection.injectKeyboard(winDown, swapOptionCommand: false)
        XCTAssertEqual(injection.heldModifiers, [0x37], "default: Win -> Command")

        injection.injectKeyboard(KeyboardData(vkCode: 0x5B, flags: LLKHFFlag.up.rawValue), swapOptionCommand: false)
        XCTAssertTrue(injection.heldModifiers.isEmpty)

        injection.injectKeyboard(winDown, swapOptionCommand: true)
        XCTAssertEqual(injection.heldModifiers, [0x3A], "swapped: Win -> Option")
    }

    func testReleaseAllKeysClearsState() {
        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL
        injection.injectKeyboard(KeyboardData(vkCode: 0x5B, flags: 0))  // VK_LWIN
        injection.injectKeyboard(KeyboardData(vkCode: 0x14, flags: 0))  // VK_CAPITAL (locks on)
        XCTAssertEqual(injection.heldModifiers.count, 2)

        injection.releaseAllKeys()
        XCTAssertTrue(injection.heldModifiers.isEmpty)
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskControl))
        XCTAssertFalse(injection.currentModifierFlags.contains(.maskCommand))
        // Caps Lock survives releaseAllKeys (hardware toggle semantics).
        XCTAssertTrue(injection.currentModifierFlags.contains(.maskAlphaShift))
    }

    func testResetReleasesModifiers() {
        let injection = InputInjection()
        injection.injectKeyboard(KeyboardData(vkCode: 0xA2, flags: 0))  // VK_LCONTROL
        injection.reset()
        XCTAssertTrue(injection.heldModifiers.isEmpty)
    }

    // MARK: - Scroll inversion

    func testScrollPixelConversion() {
        XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: false), 3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: -120, invert: false), -3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 240, invert: false), 6)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 0, invert: false), 0)
        // Inverted flips the direction.
        XCTAssertEqual(InputInjection.scrollPixels(delta: 120, invert: true), -3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: -120, invert: true), 3)
        XCTAssertEqual(InputInjection.scrollPixels(delta: 0, invert: true), 0)
    }

    // MARK: - Mouse button release on loss of control

    /// Maps virtual (60000, 60000) to a quiet point on a 1920x1080 logical
    /// screen: the injected down/up pairs click a harmless desktop area away
    /// from the Dock and menu bar.
    private func makeInjection() -> InputInjection {
        let injection = InputInjection()
        injection.screenBoundsProvider = { CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        return injection
    }

    func testResetReleasesHeldMouseButtons() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        XCTAssertTrue(injection.leftDown)

        // reset() models connection loss / crossing end while the button is
        // held: the sender never delivers the mouse-up (reference
        // ReleaseAllKeys is keyboard-only), so we must self-release.
        injection.reset()
        XCTAssertFalse(injection.leftDown)
    }

    func testReleaseAllMouseButtonsClearsAllButtons() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.rButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.mButtonDown.rawValue))
        XCTAssertTrue(injection.leftDown)
        XCTAssertTrue(injection.rightDown)
        XCTAssertTrue(injection.otherDown)

        injection.releaseAllMouseButtons()
        XCTAssertFalse(injection.leftDown)
        XCTAssertFalse(injection.rightDown)
        XCTAssertFalse(injection.otherDown)
    }

    /// A second LBUTTONDOWN with no LBUTTONUP in between (lost packet,
    /// machine switch, or sender-swallowed up) must resynchronize the stream
    /// by injecting the missing mouse-up before the new mouse-down. Injected
    /// events must carry a nonzero event number (kCGMouseEventNumber, assigned
    /// by the window server from the shared CGEventSource on injection) so
    /// the macOS gesture stack can bind them.
    func testStaleButtonDownInjectsMissingUpAndCarriesEventNumber() throws {
        let injection = makeInjection()
        let target = injection.mapVirtualToScreen(x: 60000, y: 60000)

        // CGEventPost is silently dropped for processes without accessibility
        // trust; nothing would be observable. The sequence is then verified by
        // the manual Windows→Mac smoke test instead.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Test host lacks accessibility trust")
        }

        let tap = InjectedEventTap()
        guard tap.start(at: target) else {
            throw XCTSkip("No event tap available in this environment")
        }
        defer { tap.stop() }

        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))

        let observed = tap.waitForObservations(3)
        XCTAssertEqual(observed.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown])
        for event in observed {
            XCTAssertNotEqual(
                event.eventNumber, 0,
                "injected \(event.type) must carry a nonzero event number (kCGMouseEventNumber)")
        }
    }

    // MARK: - Click state synthesis

    func testClickCountAdvancesWithinDistanceAndTimeWindow() {
        let injection = makeInjection()

        // Physical double click: down, up, down at nearly the same point.
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonUp.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .left), 1)

        injection.injectMouse(MouseData(x: 60001, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .left), 2, "second press at the same point must count as a double click")
    }

    func testClickCountResetsWhenPositionMovesAway() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonUp.rawValue))

        // ~146 points away (65535 space spans 1920 points): a different target.
        injection.injectMouse(MouseData(x: 65000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .left), 1, "a press on a different target starts a new chain")
    }

    func testClickCountResetsAfterDoubleClickInterval() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonUp.rawValue))

        // Slow presses beyond the system double-click interval stay single.
        let interval = Double(NSEvent.doubleClickInterval)
        Thread.sleep(forTimeInterval: interval + 0.1)
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .left), 1)
    }

    func testClickChainsAreTrackedPerButton() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonUp.rawValue))

        // A quick right press must not extend the left-button chain.
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.rButtonDown.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .right), 1)
        XCTAssertEqual(injection.currentClickCount(for: .left), 1)
    }

    func testResetClearsClickChains() {
        let injection = makeInjection()
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonUp.rawValue))
        injection.injectMouse(MouseData(x: 60000, y: 60000, dwFlags: WMMouseMessage.lButtonDown.rawValue))
        XCTAssertEqual(injection.currentClickCount(for: .left), 2)

        injection.reset()
        XCTAssertEqual(injection.currentClickCount(for: .left), 1)
    }
}

// MARK: - Test event tap

/// Session-level tap that observes (and when possible suppresses) the events
/// ``InputInjection`` posts during tests. Mirrors the CGEventTap bridge
/// pattern used by InputCapture.
private final class InjectedEventTap {
    struct Observed {
        let type: CGEventType
        let eventNumber: Int64
    }

    private let lock = NSLock()
    private var observations: [Observed] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppress = false
    private var filterPoint = CGPoint.zero

    /// Creates a session tap for left-click events at `point`. Prefers an
    /// active (suppressing) tap; falls back to listen-only. Returns false if
    /// neither can be created (e.g. headless session).
    @discardableResult
    func start(at point: CGPoint) -> Bool {
        filterPoint = point
        injectedEventTapBridge = self

        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)

        var created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: injectedEventTapCallback,
            userInfo: nil
        )
        suppress = created != nil
        if created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: injectedEventTapCallback,
                userInfo: nil
            )
        }
        guard let tap = created else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        injectedEventTapBridge = nil
    }

    /// Pumps the main run loop until `count` observations arrive or the
    /// timeout elapses, then returns everything observed.
    func waitForObservations(_ count: Int, timeout: TimeInterval = 2) -> [Observed] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ observations.count }) >= count {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return lock.withLock { observations }
    }

    /// Records the event when it matches the filter point; returns whether
    /// the event should be suppressed from delivery to apps.
    func handle(_ event: CGEvent) -> Bool {
        let location = event.location
        guard abs(location.x - filterPoint.x) < 1.0, abs(location.y - filterPoint.y) < 1.0 else {
            return false
        }
        let observed = Observed(
            type: event.type,
            // kCGMouseEventNumber: assigned from the shared CGEventSource.
            eventNumber: event.getIntegerValueField(CGEventField(rawValue: 98)!))
        lock.withLock { observations.append(observed) }
        return suppress
    }
}

/// Bridge for the C callback (closures with captures cannot be C function
/// pointers).
nonisolated(unsafe) private var injectedEventTapBridge: InjectedEventTap?

private func injectedEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }
    guard let bridge = injectedEventTapBridge else {
        return Unmanaged.passUnretained(event)
    }
    return bridge.handle(event) ? nil : Unmanaged.passUnretained(event)
}
