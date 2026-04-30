import Foundation

class MockEventSink {
    struct MouseEvent {
        let x: Int32
        let y: Int32
        let flags: UInt32
    }

    var injectedMouseEvents: [MouseEvent] = []

    func injectMouse(x: Int32, y: Int32, flags: UInt32) {
        injectedMouseEvents.append(MouseEvent(x: x, y: y, flags: flags))
    }
}
