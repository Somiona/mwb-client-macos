import XCTest
@testable import MWBClient

final class ConnectionStateTests: XCTestCase {
    func testHandshakeRequiresCBCShift() {
        let stream = MockByteStream()
        // The implementation should write 16 bytes immediately upon connection
        // stream.write(...)
        
        // This test asserts that the Windows behavior (16 byte random read/write)
        // is expected by our client before Handshake starts.
        // It will likely fail until the implementation is updated to support it.
        XCTAssertTrue(stream.writtenData.first?.count == 16, "Must write 16 bytes for CBC shift before any packets.")
    }
    
    func testHandshakeIgnoresDuplicates() {
        var handler = HandshakeHandler()
        handler.start()
        var packet = MWBPacket()
        packet.type = 126
        
        // Send 10 identical handshake packets (like Windows does)
        for _ in 0..<10 {
            _ = handler.receiveChallenge(packet, localMachineName: "Mac")
        }
        
        // Should only transition state once
        XCTAssertEqual(handler.state, .receivingChallenge, "Should handle 10 duplicate handshake packets cleanly.")
    }
}
