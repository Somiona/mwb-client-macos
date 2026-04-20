import Testing
import AppKit
import CoreGraphics
@testable import MWBClient

// MARK: - Semi-Automated Integration Tests
//
// These tests require:
// 1. Accessibility permission granted to the test runner
// 2. User interaction (moving mouse, pressing keys)
//
// Run with: xcodebuild test -scheme MWBClient -only-testing:MWBClientTests/InputIntegrationTests
//
// If accessibility permission is not granted, tests will be skipped.

/// Helper to check if we can run integration tests (need accessibility permission).
private func canRunIntegrationTests() -> Bool {
    AXIsProcessTrusted()
}

/// Prompt for accessibility permission if not granted.
private func promptAccessibility() {
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    let options: CFDictionary = [promptKey: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

@Suite(.serialized)
@MainActor
struct InputIntegrationTests {

    // MARK: - InputCapture Integration

    @Test("InputCapture captures real mouse move events")
    func testCaptureMouseMove() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let capture = InputCapture()
        let receivedEvents = LockedArray<MouseData>()
        let receivedPositions = LockedArray<(MouseData, CGPoint)>()

        capture.onMouseEvent = { data in
            receivedEvents.append(data)
        }
        capture.onMousePosition = { data, point in
            receivedPositions.append((data, point))
        }

        let started = capture.start()
        #expect(started)

        print(">>> Please move your mouse...")
        try await Task.sleep(for: .seconds(3))

        capture.stop()

        #expect(!receivedEvents.items.isEmpty)
        #expect(!receivedPositions.items.isEmpty)

        let moveEvents = receivedEvents.items.filter { $0.dwFlags == WMMouseMessage.mouseMove.rawValue }
        #expect(!moveEvents.isEmpty)

        for event in moveEvents {
            #expect(event.x >= 0 && event.x <= 65535)
            #expect(event.y >= 0 && event.y <= 65535)
        }

        for (_, point) in receivedPositions.items {
            #expect(point.x >= 0)
            #expect(point.y >= 0)
        }
    }

    @Test("InputCapture captures real keyboard events")
    func testCaptureKeyboard() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let capture = InputCapture()
        let receivedEvents = LockedArray<KeyboardData>()

        capture.onKeyboardEvent = { data in
            receivedEvents.append(data)
        }

        let started = capture.start()
        #expect(started)

        print(">>> Please press any key (e.g. spacebar)...")
        try await Task.sleep(for: .seconds(3))

        capture.stop()

        #expect(!receivedEvents.items.isEmpty)

        let keyDowns = receivedEvents.items.filter { !$0.isKeyUp }
        #expect(!keyDowns.isEmpty)

        let mappedCodes = keyDowns.filter { $0.vkCode != 0 }
        #expect(!mappedCodes.isEmpty)
    }

    @Test("InputCapture suppresses events when crossingActive is true")
    func testEventSuppression() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let capture = InputCapture()
        let mouseEventsDuringCrossing = LockedArray<MouseData>()

        capture.onMouseEvent = { data in
            mouseEventsDuringCrossing.append(data)
        }

        let started = capture.start()
        #expect(started)

        capture.crossingActive = true

        print(">>> Move mouse while crossing is active (cursor should not move)...")
        try await Task.sleep(for: .seconds(2))

        let eventsDuringCrossing = mouseEventsDuringCrossing.items.count

        capture.crossingActive = false
        mouseEventsDuringCrossing.removeAll()

        print(">>> Now move mouse normally (cursor should move)...")
        try await Task.sleep(for: .seconds(2))

        capture.stop()

        #expect(eventsDuringCrossing > 0)
        #expect(mouseEventsDuringCrossing.items.count > 0)
    }

    // MARK: - InputInjection Integration

    @Test("InputInjection moves cursor to specified position")
    func testInjectionMouseMove() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let injection = InputInjection()

        let data = MouseData(
            x: 32767,
            y: 32767,
            wheelDelta: 0,
            dwFlags: WMMouseMessage.mouseMove.rawValue
        )
        injection.injectMouse(data)

        try await Task.sleep(for: .milliseconds(100))

        let cursorLocation = NSEvent.mouseLocation
        let screenFrame = NSScreen.main?.frame ?? .zero

        let tolerance: CGFloat = 100
        #expect(abs(cursorLocation.x - screenFrame.midX) < tolerance)
        #expect(abs(cursorLocation.y - screenFrame.midY) < tolerance)
    }

    // MARK: - EdgeDetector Integration

    @Test("EdgeDetector triggers crossing when cursor hits right edge")
    func testEdgeDetectionAtRightEdge() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let capture = InputCapture()
        let detector = EdgeDetector()
        detector.crossingEdge = .right
        detector.threshold = 5.0
        detector.debounceInterval = 0.05

        let crossingResult = LockedValue<CrossingStartInfo>()

        detector.crossingStart = { info in
            crossingResult.set(info)
        }

        nonisolated(unsafe) let unsafeDetector = detector
        capture.onMousePosition = { data, point in
            MainActor.assumeIsolated {
                unsafeDetector.updateCursorPosition(data, screenPoint: point)
            }
        }

        let started = capture.start()
        #expect(started)

        print(">>> Please move cursor to the RIGHT edge of the screen and hold for 0.5s...")
        try await Task.sleep(for: .seconds(4))

        capture.stop()

        guard let info = crossingResult.value else {
            #expect(crossingResult.value != nil)
            return
        }
        #expect(info.edge == .right)

        detector.reset()
    }

    // MARK: - Full Pipeline

    @Test("Full pipeline: capture -> coordinate roundtrip -> inject back")
    func testFullPipelineRoundtrip() async throws {
        guard canRunIntegrationTests() else {
            print("SKIP: Accessibility permission not granted")
            return
        }

        let capture = InputCapture()
        let injection = InputInjection()
        let capturedPositions = LockedArray<MouseData>()

        capture.onMouseEvent = { data in
            if data.dwFlags == WMMouseMessage.mouseMove.rawValue {
                capturedPositions.append(data)
            }
        }

        let started = capture.start()
        #expect(started)

        print(">>> Move the mouse around for 2 seconds...")
        try await Task.sleep(for: .seconds(2))

        if let lastCaptured = capturedPositions.items.last {
            injection.injectMouse(lastCaptured)
            try await Task.sleep(for: .milliseconds(100))
        }

        capture.stop()

        #expect(!capturedPositions.items.isEmpty)

        for event in capturedPositions.items {
            #expect(event.x >= 0 && event.x <= 65535)
            #expect(event.y >= 0 && event.y <= 65535)
        }
    }
}

// MARK: - Thread-safe helpers for @Sendable closures

/// Thread-safe array wrapper for use in @Sendable closures.
private final class LockedArray<T>: @unchecked Sendable {
    private var _items: [T] = []
    private let lock = NSLock()

    var items: [T] {
        lock.lock()
        defer { lock.unlock() }
        return _items
    }

    func append(_ item: T) {
        lock.lock()
        _items.append(item)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        _items.removeAll()
        lock.unlock()
    }
}

/// Thread-safe single-value holder for use in @Sendable closures.
private final class LockedValue<T>: @unchecked Sendable {
    private var _value: T?
    private let lock = NSLock()

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: T?) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}
