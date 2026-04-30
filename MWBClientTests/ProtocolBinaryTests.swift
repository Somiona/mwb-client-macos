import XCTest
@testable import MWBClient

final class ProtocolBinaryTests: XCTestCase {
    func testHandshakePacketMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "handshake", withExtension: "bin", subdirectory: "Fixtures")!
        let goldenData = try Data(contentsOf: url)

        var packet = MWBPacket()
        packet.type = 126

        var dataField = Data(count: MWBConstants.dataFieldSize)
        for i in 0..<16 {
            dataField[i] = UInt8(16 + i)
        }
        let nameData = HandshakeHandler.encodeMachineName("WIN-REF")
        dataField.replaceSubrange(16..<48, with: nameData)
        packet.data = dataField

        var testBytes = [UInt8](packet.rawBytes)
        var goldBytes = [UInt8](goldenData)
        testBytes[1...3] = [0, 0, 0]
        goldBytes[1...3] = [0, 0, 0]

        XCTAssertEqual(testBytes, goldBytes, "Packet serialization must match Windows reference exactly.")
    }
}
