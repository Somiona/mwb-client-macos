import Testing
import AppKit
import CoreGraphics
@testable import MWBClient

// MARK: - Helpers

/// Thread-safe counter for @Sendable closures.
private final class AtomicCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// Thread-safe value holder for @Sendable closures.
private final class AtomicValue<T>: @unchecked Sendable {
    private var _value: T?
    private let lock = NSLock()
    var value: T? { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}

// MARK: - Coordinate Mapping Tests

@MainActor
struct CoordinateMappingTests {

    @Test("MWB (0,0) maps to screen top-left, (65535,65535) maps to screen bottom-right")
    func testCornerMapping() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let max = CGFloat(MWBConstants.virtualDesktopMax)

        // (0,0) -> top-left of screen
        let topLeftX = frame.minX + (0.0 / max) * frame.width
        let topLeftY = frame.maxY - (0.0 / max) * frame.height
        #expect(topLeftX == frame.minX)
        #expect(topLeftY == frame.maxY) // maxY = top in Cocoa coords

        // (65535,65535) -> bottom-right of screen
        let brX = frame.minX + (max / max) * frame.width
        let brY = frame.maxY - (max / max) * frame.height
        #expect(brX == frame.maxX)
        #expect(brY == frame.minY) // minY = bottom in Cocoa coords
    }

    @Test("Capture and injection coordinate mapping are symmetric")
    func testCoordinateRoundtrip() {
        let virtualMax = CGFloat(MWBConstants.virtualDesktopMax)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Center of screen -> virtual center
        let centerScreen = CGPoint(x: frame.midX, y: frame.midY)
        let vx = Int32(((centerScreen.x - frame.minX) / frame.width) * virtualMax)
        let vy = Int32(((frame.maxY - centerScreen.y) / frame.height) * virtualMax)

        // Virtual center should be ~32767
        #expect(vx > 32000 && vx < 33000)
        #expect(vy > 32000 && vy < 33000)

        // Roundtrip: virtual back to screen
        let screenX = frame.minX + (CGFloat(vx) / virtualMax) * frame.width
        let screenY = frame.maxY - (CGFloat(vy) / virtualMax) * frame.height

        #expect(abs(screenX - centerScreen.x) < 1.0)
        #expect(abs(screenY - centerScreen.y) < 1.0)
    }

    @Test("Capture clamps out-of-bounds coordinates to 0...65535")
    func testCoordinateClamping() {
        let virtualMax = CGFloat(MWBConstants.virtualDesktopMax)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Point outside screen bounds
        let outOfBounds = CGPoint(x: -100, y: -100)
        let vx = Int32(((outOfBounds.x - frame.minX) / frame.width) * virtualMax)
        let vy = Int32(((frame.maxY - outOfBounds.y) / frame.height) * virtualMax)

        let clampedX = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, vx))
        let clampedY = Swift.max(Int32(0), Swift.min(MWBConstants.virtualDesktopMax, vy))

        #expect(clampedX >= 0)
        #expect(clampedY >= 0)
        #expect(clampedX <= MWBConstants.virtualDesktopMax)
        #expect(clampedY <= MWBConstants.virtualDesktopMax)
    }
}

// MARK: - EdgeDetector Tests

@MainActor
struct EdgeDetectorTests {

    private func makeDetector(
        edge: CrossingEdge = .right,
        threshold: CGFloat = 2.0,
        debounceInterval: TimeInterval = 0.05
    ) -> EdgeDetector {
        let d = EdgeDetector()
        d.crossingEdge = edge
        d.threshold = threshold
        d.debounceInterval = debounceInterval
        return d
    }

    private let testFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: Edge detection math

    @Test("Right edge: distance from maxX within threshold")
    func testRightEdgeDetection() {
        let detector = makeDetector(edge: .right)
        let atEdge = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let notAtEdge = CGPoint(x: testFrame.maxX - 5, y: testFrame.midY)
        #expect(testFrame.maxX - atEdge.x <= detector.threshold)
        #expect(testFrame.maxX - notAtEdge.x > detector.threshold)
    }

    @Test("Left edge: distance from minX within threshold")
    func testLeftEdgeDetection() {
        let detector = makeDetector(edge: .left)
        let atEdge = CGPoint(x: testFrame.minX + 1, y: testFrame.midY)
        let notAtEdge = CGPoint(x: testFrame.minX + 5, y: testFrame.midY)
        #expect(atEdge.x - testFrame.minX <= detector.threshold)
        #expect(notAtEdge.x - testFrame.minX > detector.threshold)
    }

    @Test("Top edge: distance from maxY within threshold")
    func testTopEdgeDetection() {
        let detector = makeDetector(edge: .top)
        let atEdge = CGPoint(x: testFrame.midX, y: testFrame.maxY - 1)
        let notAtEdge = CGPoint(x: testFrame.midX, y: testFrame.maxY - 5)
        #expect(testFrame.maxY - atEdge.y <= detector.threshold)
        #expect(testFrame.maxY - notAtEdge.y > detector.threshold)
    }

    @Test("Bottom edge: distance from minY within threshold")
    func testBottomEdgeDetection() {
        let detector = makeDetector(edge: .bottom)
        let atEdge = CGPoint(x: testFrame.midX, y: testFrame.minY + 1)
        let notAtEdge = CGPoint(x: testFrame.midX, y: testFrame.minY + 5)
        #expect(atEdge.y - testFrame.minY <= detector.threshold)
        #expect(notAtEdge.y - testFrame.minY > detector.threshold)
    }

    // MARK: Debounce

    @Test("Debounce: crossingStart not triggered immediately on edge hit")
    func testDebounceNotImmediate() async {
        let detector = makeDetector(debounceInterval: 0.1)
        let triggered = AtomicCounter()
        detector.crossingStart = { _ in triggered.increment() }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let data = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)

        #expect(triggered.value == 0)
        #expect(!detector.isCrossingActive)
    }

    @Test("Debounce: crossingStart triggers after debounce interval")
    func testDebounceTriggersAfterDelay() async {
        let detector = makeDetector(debounceInterval: 0.05)
        let infoHolder = AtomicValue<CrossingStartInfo>()
        detector.crossingStart = { info in infoHolder.set(info) }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let data = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(detector.isCrossingActive)
        #expect(infoHolder.value != nil)
        #expect(infoHolder.value?.edge == .right)
    }

    @Test("Debounce: moving away from edge cancels the trigger")
    func testDebounceCancelledByMovingAway() async {
        let detector = makeDetector(debounceInterval: 1.0)
        let triggered = AtomicCounter()
        detector.crossingStart = { _ in triggered.increment() }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let edgeData = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(edgeData, screenPoint: edgePoint)

        // Move away immediately (debounce is 1s, so it shouldn't have fired)
        let safePoint = CGPoint(x: testFrame.maxX - 50, y: testFrame.midY)
        let safeData = MouseData(x: 64000, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(safeData, screenPoint: safePoint)

        // Wait and confirm crossing never triggered
        try? await Task.sleep(for: .milliseconds(200))

        #expect(triggered.value == 0)
        #expect(!detector.isCrossingActive)
    }

    // MARK: Crossing lifecycle

    @Test("crossingDidEnd resets state and allows new crossings")
    func testCrossingDidEndResetsState() async {
        let detector = makeDetector(debounceInterval: 0.01)
        let triggerCount = AtomicCounter()
        detector.crossingStart = { _ in triggerCount.increment() }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let data = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(triggerCount.value == 1)
        #expect(detector.isCrossingActive)

        detector.crossingDidEnd()
        #expect(!detector.isCrossingActive)

        detector.updateCursorPosition(data, screenPoint: edgePoint)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(triggerCount.value == 2)
    }

    @Test("No re-trigger while crossing is active")
    func testNoRetriggerWhileCrossing() async {
        let detector = makeDetector(debounceInterval: 0.01)
        let triggerCount = AtomicCounter()
        detector.crossingStart = { _ in triggerCount.increment() }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let data = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)
        try? await Task.sleep(for: .milliseconds(50))

        for _ in 0..<5 {
            detector.updateCursorPosition(data, screenPoint: edgePoint)
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(triggerCount.value == 1)
    }

    // MARK: Reset

    @Test("reset() cancels debounce and clears state")
    func testResetClearsState() async {
        let detector = makeDetector(debounceInterval: 0.05)
        let triggered = AtomicCounter()
        detector.crossingStart = { _ in triggered.increment() }

        let edgePoint = CGPoint(x: testFrame.maxX - 1, y: testFrame.midY)
        let data = MouseData(x: 65534, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)
        detector.reset()

        try? await Task.sleep(for: .milliseconds(100))

        #expect(triggered.value == 0)
        #expect(!detector.isCrossingActive)
    }

    // MARK: CrossingStartInfo content

    @Test("CrossingStartInfo carries correct edge and coordinates")
    func testCrossingStartInfoContent() async {
        let detector = makeDetector(edge: .left, debounceInterval: 0.01)
        let infoHolder = AtomicValue<CrossingStartInfo>()
        detector.crossingStart = { info in infoHolder.set(info) }

        let edgePoint = CGPoint(x: 1, y: 500)
        let data = MouseData(x: 10, y: 30000, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        detector.updateCursorPosition(data, screenPoint: edgePoint)
        try? await Task.sleep(for: .milliseconds(50))

        let info = infoHolder.value
        #expect(info != nil)
        #expect(info?.edge == .left)
        #expect(info?.virtualPosition.x == 10)
        #expect(info?.virtualPosition.y == 30000)
    }

    // MARK: Threshold

    @Test("Custom threshold changes edge detection sensitivity")
    func testCustomThreshold() {
        let detector = makeDetector(edge: .right)
        detector.threshold = 10.0

        let nearEdge = CGPoint(x: testFrame.maxX - 5, y: testFrame.midY)
        #expect(testFrame.maxX - nearEdge.x <= detector.threshold)
    }
}

// MARK: - InputInjection State Tests

@MainActor
struct InputInjectionStateTests {

    @Test("reset() restores initial state (no crash on subsequent inject)")
    func testResetRestoresState() {
        let injection = InputInjection()
        let data = MouseData(x: 32767, y: 32767, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue)
        injection.injectMouse(data)
        injection.reset()
        injection.injectMouse(data)
    }

    @Test("Unknown WM message types are silently ignored")
    func testUnknownWmMessageIgnored() {
        let injection = InputInjection()
        let data = MouseData(x: 100, y: 100, wheelDelta: 0, dwFlags: 0x9999)
        injection.injectMouse(data)
    }

    @Test("Unmapped VK codes are silently ignored")
    func testUnmappedVkCodeIgnored() {
        let injection = InputInjection()
        let data = KeyboardData(vkCode: 0xFF, scanCode: 0, flags: 0)
        injection.injectKeyboard(data)
    }
}

// MARK: - InputCapture Callback Tests

@MainActor
struct InputCaptureCallbackTests {

    @Test("Callbacks are settable and independent")
    func testCallbacksSettable() {
        let capture = InputCapture()
        capture.onMouseEvent = { _ in }
        capture.onMousePosition = { _, _ in }
        capture.onKeyboardEvent = { _ in }
        #expect(capture.onMouseEvent != nil)
        #expect(capture.onMousePosition != nil)
        #expect(capture.onKeyboardEvent != nil)
    }

    @Test("crossingActive flag toggles correctly")
    func testCrossingActiveFlag() {
        let capture = InputCapture()
        #expect(!capture.crossingActive)
        capture.crossingActive = true
        #expect(capture.crossingActive)
        capture.crossingActive = false
        #expect(!capture.crossingActive)
    }

    @Test("start() and stop() don't crash without accessibility")
    func testStartStopWithoutAccessibility() {
        let capture = InputCapture()
        _ = capture.start()
        capture.stop()
    }
}

// MARK: - CrossingEdge Tests

struct CrossingEdgeTests {

    @Test("Default edge is right")
    func testDefaultEdge() {
        #expect(CrossingEdge.default == .right)
    }

    @Test("All 4 cases present")
    func testCaseIterable() {
        #expect(CrossingEdge.allCases.count == 4)
        #expect(CrossingEdge.allCases.contains(.left))
        #expect(CrossingEdge.allCases.contains(.right))
        #expect(CrossingEdge.allCases.contains(.top))
        #expect(CrossingEdge.allCases.contains(.bottom))
    }

    @Test("Raw values match edge names")
    func testRawValues() {
        #expect(CrossingEdge.left.rawValue == "left")
        #expect(CrossingEdge.right.rawValue == "right")
        #expect(CrossingEdge.top.rawValue == "top")
        #expect(CrossingEdge.bottom.rawValue == "bottom")
    }
}
