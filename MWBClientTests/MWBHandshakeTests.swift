import XCTest
@testable import MWBClient

final class MWBHandshakeTests: XCTestCase {

    func testHandshakeChallengeResponseFlipsBits() throws {
        var handler = HandshakeHandler()
        handler.start()

        var challengePacket = MWBPacket()
        challengePacket.type = PackageType.handshake.rawValue
        
        // Populate 16 bytes of data
        for i in 0..<4 {
            challengePacket.setDataUInt32(0x11223344 + UInt32(i), at: i * 4)
        }

        let ackPacket = handler.receiveChallenge(challengePacket, localMachineName: "Test", localMachineID: MachineID(rawValue: 1))
        let unwrappedAck = try XCTUnwrap(ackPacket)
        
        // Verify bitwise NOT
        for i in 0..<4 {
            let original = 0x11223344 + UInt32(i)
            let flipped = unwrappedAck.dataUInt32(at: i * 4)
            XCTAssertEqual(flipped, ~original)
        }
    }

    func testEncodeMachineName() {
        // "Test"
        let data1 = HandshakeHandler.encodeMachineName("Test")
        XCTAssertEqual(data1.count, 32)
        XCTAssertEqual(String(data: data1.prefix(4), encoding: .ascii), "Test")
        XCTAssertEqual(data1[4], 0x20) // space padding
        XCTAssertEqual(data1[31], 0x20) // space padding
        
        // Unicode replacement
        let data2 = HandshakeHandler.encodeMachineName("Test🚀")
        XCTAssertEqual(data2.count, 32)
        XCTAssertEqual(String(data: data2.prefix(4), encoding: .ascii), "Test")
        XCTAssertEqual(data2[4], 0x3F) // '?' for non-ascii
        XCTAssertEqual(data2[5], 0x20) // space
    }
    
    func testHandshakeStateTransitions() {
        var handler = HandshakeHandler()
        XCTAssertEqual(handler.state, .idle)
        
        handler.start()
        XCTAssertEqual(handler.state, .exchangingNoise)
        
        var packet = MWBPacket()
        packet.type = PackageType.handshake.rawValue
        
        for _ in 0..<MWBConstants.handshakeIterationCount {
            _ = handler.receiveChallenge(packet, localMachineName: "Mac", localMachineID: MachineID(rawValue: 1))
        }
        XCTAssertEqual(handler.state, .receivingChallenge)
        
        let ready = handler.completeIfReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(handler.state, .sendingIdentity)
        
        handler.completeIdentity()
        XCTAssertEqual(handler.state, .completed)
    }
}
