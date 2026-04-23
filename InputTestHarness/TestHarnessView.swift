import SwiftUI
@testable import MWBClient

struct TestHarnessView: View {
    var body: some View {
        TabView {
            CaptureTestTab()
                .tabItem { Label("Capture", systemImage: "cursorarrow.motionlines") }

            InjectionTestTab()
                .tabItem { Label("Injection", systemImage: "cursorarrow.click") }

            EdgeDetectionTab()
                .tabItem { Label("Edge Detect", systemImage: "arrow.right.to.line") }

            CoordinateTestTab()
                .tabItem { Label("Coordinates", systemImage: "chart.xyaxis.line") }
        }
        .padding()
    }
}

// MARK: - Capture Test

struct CaptureTestTab: View {
    @State private var capture = InputCapture()
    @State private var isRunning = false
    @State private var eventCount = 0
    @State private var lastMouseEvent = "None"
    @State private var lastKeyboardEvent = "None"
    @State private var crossingActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input Capture Test")
                .font(.headline)

            HStack {
                Button(isRunning ? "Stop" : "Start Capture") {
                    if isRunning {
                        capture.stop()
                    } else {
                        isRunning = capture.start()
                    }
                }
                .disabled(!isRunning && !InputCapture.hasAccessibilityPermission())

                Toggle("Crossing Active (suppress events)", isOn: $crossingActive)
                    .onChange(of: crossingActive) { _, newValue in
                        capture.crossingActive = newValue
                    }
            }

            GroupBox("Permission") {
                HStack {
                    Circle()
                        .fill(InputCapture.hasAccessibilityPermission() ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(InputCapture.hasAccessibilityPermission() ? "Granted" : "Not granted")
                }
                if !InputCapture.hasAccessibilityPermission() {
                    Button("Open System Settings") {
                        InputCapture.requestAccessibilityPermission()
                    }
                }
            }

            GroupBox("Statistics") {
                LabeledContent("Total events", value: "\(eventCount)")
                LabeledContent("Last mouse", value: lastMouseEvent)
                LabeledContent("Last keyboard", value: lastKeyboardEvent)
            }
            .font(.system(.body, design: .monospaced))

            Spacer()

            Text("Move your mouse or press keys. Events appear above.")
                .foregroundStyle(.secondary)
        }
        .onDisappear { capture.stop() }
        .onAppear {
            capture.onMouseEvent = { data in
                eventCount += 1
                let name = data.wmMessage.map { String(describing: $0) } ?? "unknown"
                lastMouseEvent = "\(name) x=\(data.x) y=\(data.y)"
            }
            capture.onKeyboardEvent = { data in
                eventCount += 1
                let direction = data.isKeyUp ? "UP" : "DOWN"
                lastKeyboardEvent = "VK_\(String(data.vkCode, radix: 16)) \(direction)"
            }
        }
    }
}

// MARK: - Injection Test

struct InjectionTestTab: View {
    @State private var injection = InputInjection()
    @State private var injectX: Double = 32767
    @State private var injectY: Double = 32767

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input Injection Test")
                .font(.headline)

            GroupBox("Cursor Movement") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("X (virtual):")
                        Slider(value: $injectX, in: 0...65535)
                        Text("\(Int(injectX))")
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Y (virtual):")
                        Slider(value: $injectY, in: 0...65535)
                        Text("\(Int(injectY))")
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                    HStack {
                        Button("Move Cursor") {
                            let data = MouseData(
                                x: Int32(injectX), y: Int32(injectY),
                                wheelDelta: 0,
                                dwFlags: WMMouseMessage.mouseMove.rawValue
                            )
                            injection.injectMouse(data)
                        }
                        Button("Move to Center") {
                            injectX = 32767; injectY = 32767
                            let data = MouseData(
                                x: 32767, y: 32767,
                                wheelDelta: 0,
                                dwFlags: WMMouseMessage.mouseMove.rawValue
                            )
                            injection.injectMouse(data)
                        }
                        Button("Move to Top-Left") {
                            injectX = 0; injectY = 0
                            injection.injectMouse(MouseData(x: 0, y: 0, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue))
                        }
                        Button("Move to Bottom-Right") {
                            injectX = 65535; injectY = 65535
                            injection.injectMouse(MouseData(x: 65535, y: 65535, wheelDelta: 0, dwFlags: WMMouseMessage.mouseMove.rawValue))
                        }
                    }
                }
            }

            GroupBox("Mouse Buttons") {
                HStack {
                    Button("Left Down") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 0, dwFlags: WMMouseMessage.lButtonDown.rawValue)) }
                    Button("Left Up") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 0, dwFlags: WMMouseMessage.lButtonUp.rawValue)) }
                    Button("Right Down") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 0, dwFlags: WMMouseMessage.rButtonDown.rawValue)) }
                    Button("Right Up") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 0, dwFlags: WMMouseMessage.rButtonUp.rawValue)) }
                }
            }

            GroupBox("Scroll") {
                HStack {
                    Button("Scroll Up +3") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 360, dwFlags: WMMouseMessage.mouseWheel.rawValue)) }
                    Button("Scroll Down -3") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: -360, dwFlags: WMMouseMessage.mouseWheel.rawValue)) }
                    Button("Scroll Right") { injection.injectMouse(MouseData(x: Int32(injectX), y: Int32(injectY), wheelDelta: 360, dwFlags: WMMouseMessage.mouseHWheel.rawValue)) }
                }
            }

            GroupBox("Keyboard") {
                HStack {
                    Button("Press A") { injection.injectKeyboard(KeyboardData(vkCode: 0x41, flags: 0)) }
                    Button("Release A") { injection.injectKeyboard(KeyboardData(vkCode: 0x41, flags: 0x80)) }
                    Button("Press Space") { injection.injectKeyboard(KeyboardData(vkCode: 0x20, flags: 0)) }
                    Button("Release Space") { injection.injectKeyboard(KeyboardData(vkCode: 0x20, flags: 0x80)) }
                }
            }

            Button("Reset Injection State") {
                injection.reset()
            }

            Spacer()
        }
    }
}

// MARK: - Edge Detection Test

struct EdgeDetectionTab: View {
    @State private var capture = InputCapture()
    @State private var detector = EdgeDetector()
    @State private var isRunning = false
    @State private var crossingLog: [String] = []
    @State private var selectedEdge: CrossingEdge = .right

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edge Detection Test")
                .font(.headline)

            HStack {
                Button(isRunning ? "Stop" : "Start") {
                    if isRunning {
                        capture.stop()
                        detector.reset()
                    } else {
                        isRunning = capture.start()
                    }
                }

                Picker("Edge", selection: $selectedEdge) {
                    ForEach(CrossingEdge.allCases, id: \.self) { edge in
                        Text(edge.rawValue.capitalized).tag(edge)
                    }
                }
                .onChange(of: selectedEdge) { _, new in
                    detector.reset()
                    detector.crossingEdge = new
                }

                Button("Reset") {
                    detector.reset()
                    crossingLog.removeAll()
                }
            }

            GroupBox("Crossing Log") {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if crossingLog.isEmpty {
                            Text("Move cursor to the \(selectedEdge.rawValue) edge to trigger crossing...")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(crossingLog.reversed(), id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .frame(maxHeight: 250)
            }

            Spacer()
        }
        .onAppear {
            detector.crossingEdge = selectedEdge
            detector.crossingStart = { info in
                let msg = "CROSSING: edge=\(info.edge.rawValue) vpos=(\(info.virtualPosition.x),\(info.virtualPosition.y)) spos=(\(String(format: "%.0f", info.screenPosition.x)),\(String(format: "%.0f", info.screenPosition.y)))"
                crossingLog.append(msg)
                // Auto-end after 1 second to test re-triggering
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    detector.crossingDidEnd()
                    crossingLog.append("  -> crossing ended, cursor warped back")
                }
            }
            capture.onMousePosition = { data, point in
                detector.updateCursorPosition(data, screenPoint: point)
            }
        }
        .onDisappear { capture.stop() }
    }
}

// MARK: - Coordinate Roundtrip Test

struct CoordinateTestTab: View {
    @State private var capture = InputCapture()
    @State private var isRunning = false
    @State private var roundtripResults: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coordinate Roundtrip Test")
                .font(.headline)

            Text("Captures your mouse position in MWB virtual coords, then re-injects it. Cursor should stay in place.")
                .foregroundStyle(.secondary)
                .font(.caption)

            HStack {
                Button(isRunning ? "Stop" : "Start Roundtrip") {
                    if isRunning {
                        capture.stop()
                    } else {
                        isRunning = capture.start()
                    }
                }
                Button("Clear") { roundtripResults.removeAll() }
            }

            GroupBox("Results") {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if roundtripResults.isEmpty {
                            Text("Waiting for mouse movement...")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(roundtripResults.reversed(), id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Spacer()
        }
        .onAppear {
            let injection = InputInjection()
            capture.onMousePosition = { data, point in
                let msg = "screen=(\(String(format: "%.0f", point.x)),\(String(format: "%.0f", point.y))) -> virtual=(\(data.x),\(data.y))"
                roundtripResults.append(msg)
                // Re-inject every 10th event
                if roundtripResults.count % 10 == 0 {
                    injection.injectMouse(data)
                    roundtripResults.append("  -> re-injected, cursor should be at same position")
                }
            }
        }
        .onDisappear { capture.stop() }
    }
}
