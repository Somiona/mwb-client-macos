import XCTest
@testable import MWBClient

final class ConnectionStateTests: XCTestCase {
    func testHandshakeIgnoresDuplicates() {
        var handler = HandshakeHandler()
        handler.start()
        var packet = MWBPacket()
        packet.type = 126
        
        // Send 10 identical handshake packets (like Windows does)
        for _ in 0..<10 {
            _ = handler.receiveChallenge(packet, localMachineName: "Mac", localMachineID: 1)
        }
        
        // Should only transition state once
        XCTAssertEqual(handler.state, .receivingChallenge, "Should handle 10 duplicate handshake packets cleanly.")
    }
}
