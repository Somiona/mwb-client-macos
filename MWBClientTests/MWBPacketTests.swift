import XCTest
@testable import MWBClient

final class MWBPacketTests: XCTestCase {

    // 1. PackageType enums correctly map to 32-byte (Small) or 64-byte (Big) variants.
    func testPackageTypeSizes() {
        let expectedBig: [PackageType] = [
            .hello, .awake, .heartbeat, .heartbeatEx, .handshake, .handshakeAck,
            .clipboardPush, .clipboard, .clipboardAsk, .clipboardImage, .clipboardText,
            .clipboardDataEnd, .matrix
        ]
        
        for type in expectedBig {
            XCTAssertTrue(type.isBig, "\(type) should be a big packet (64 bytes)")
        }
        
        let expectedSmall: [PackageType] = [
            .hi, .byeBye, .hideMouse, .heartbeatExL2, .heartbeatExL3, .nextMachine,
            .keyboard, .mouse
        ]
        
        for type in expectedSmall {
            XCTAssertFalse(type.isBig, "\(type) should be a small packet (32 bytes)")
        }
        
        // Also test the packet's transmitted size
        var packet = MWBPacket()
        packet.packageType = .hello
        XCTAssertTrue(packet.isBig)
        XCTAssertEqual(packet.transmittedSize, 64)
        
        packet.packageType = .keyboard
        XCTAssertFalse(packet.isBig)
        XCTAssertEqual(packet.transmittedSize, 32)
    }
    
    // 2. Checksum modulo 256 logic exclusively sums bytes 2-31, exactly matching C# behavior.
    func testChecksumLogic() {
        var packet = MWBPacket()
        
        // Fill bytes 2 to 63 with a known pattern
        let rawBytes = packet.rawBytes
        var mutablePacket = packet
        
        for i in 2..<64 {
            let val = UInt8(i)
            // Using raw access or properties to set bytes
            if i < 16 {
                // Header fields
                switch i {
                case 2: mutablePacket.magic0 = val
                case 3: mutablePacket.magic1 = val
                default:
                    // Using data to mutate underlying buffer via id/src/des, but easier to use rawData init
                    break
                }
            }
        }
        
        // Let's create a specific raw Data packet to test checksum
        var data = Data(count: 64)
        var expectedSum: UInt16 = 0
        for i in 0..<64 {
            data[i] = UInt8(i)
            if i >= 2 && i < 32 {
                expectedSum += UInt16(i)
            }
        }
        let finalExpectedSum = UInt8(expectedSum % 256)
        
        var parsedPacket = MWBPacket(rawData: data)
        let computedSum = parsedPacket.computeChecksum()
        
        XCTAssertEqual(computedSum, finalExpectedSum, "Checksum should only sum bytes 2-31")
        XCTAssertEqual(parsedPacket.checksum, finalExpectedSum, "Checksum property should be set correctly")
        
        // Make sure changing byte 32 does NOT affect checksum
        data[32] = 255
        var parsedPacket2 = MWBPacket(rawData: data)
        let computedSum2 = parsedPacket2.computeChecksum()
        XCTAssertEqual(computedSum2, finalExpectedSum, "Checksum should ignore bytes 32 and above")
    }
    
    // 3. Overlapping fields map to exact byte offsets defined in docs.
    func testByteOffsets() {
        var packet = MWBPacket()
        packet.packageType = .keyboard
        packet.checksum = 0xAA
        packet.magic0 = 0xBB
        packet.magic1 = 0xCC
        packet.id = 0x11223344
        packet.src = 0x55667788
        packet.des = 0x99AABBCC
        
        let bytes = packet.rawBytes
        XCTAssertEqual(bytes[0], 122) // Keyboard
        XCTAssertEqual(bytes[1], 0xAA)
        XCTAssertEqual(bytes[2], 0xBB)
        XCTAssertEqual(bytes[3], 0xCC)
        
        // id (little endian)
        XCTAssertEqual(bytes[4], 0x44)
        XCTAssertEqual(bytes[5], 0x33)
        XCTAssertEqual(bytes[6], 0x22)
        XCTAssertEqual(bytes[7], 0x11)
        
        // src (little endian)
        XCTAssertEqual(bytes[8], 0x88)
        XCTAssertEqual(bytes[9], 0x77)
        XCTAssertEqual(bytes[10], 0x66)
        XCTAssertEqual(bytes[11], 0x55)
        
        // des (little endian)
        XCTAssertEqual(bytes[12], 0xCC)
        XCTAssertEqual(bytes[13], 0xBB)
        XCTAssertEqual(bytes[14], 0xAA)
        XCTAssertEqual(bytes[15], 0x99)
        
        // Test keyboard payload via data offset
        // In docs:
        // DateTime (16-23): offset 0 in data
        // wVk (24-27): offset 8 in data
        // dwFlags (28-31): offset 12 in data
        packet.setDataUInt32(0xDDCCBBAA, at: 8) // wVk
        let updatedBytes = packet.rawBytes
        XCTAssertEqual(updatedBytes[24], 0xAA)
        XCTAssertEqual(updatedBytes[25], 0xBB)
        XCTAssertEqual(updatedBytes[26], 0xCC)
        XCTAssertEqual(updatedBytes[27], 0xDD)
        
        // Test MouseData offsets
        var mousePacket = MWBPacket()
        mousePacket.packageType = .mouse
        var mousePayload = MouseData()
        mousePayload.x = 100
        mousePayload.y = 200
        mousePayload.wheelDelta = 120
        mousePayload.dwFlags = 0x0200
        mousePayload.write(to: &mousePacket)
        
        let mouseBytes = mousePacket.rawBytes
        // x at 16-19
        XCTAssertEqual(mouseBytes[16], 100)
        XCTAssertEqual(mouseBytes[17], 0)
        XCTAssertEqual(mouseBytes[18], 0)
        XCTAssertEqual(mouseBytes[19], 0)
        // y at 20-23
        XCTAssertEqual(mouseBytes[20], 200)
        XCTAssertEqual(mouseBytes[21], 0)
        XCTAssertEqual(mouseBytes[22], 0)
        XCTAssertEqual(mouseBytes[23], 0)
        // wheelDelta at 24-27
        XCTAssertEqual(mouseBytes[24], 120)
        XCTAssertEqual(mouseBytes[25], 0)
        XCTAssertEqual(mouseBytes[26], 0)
        XCTAssertEqual(mouseBytes[27], 0)
        // dwFlags at 28-31
        XCTAssertEqual(mouseBytes[28], 0x00)
        XCTAssertEqual(mouseBytes[29], 0x02)
        XCTAssertEqual(mouseBytes[30], 0x00)
        XCTAssertEqual(mouseBytes[31], 0x00)
        
        // Test MachineName offsets
        let identityPacket = HandshakeHandler.makeIdentityPacket(
            machineName: "TestMac", 
            screenWidth: 1920, 
            screenHeight: 1080, 
            machineID: 1
        )
        let identityBytes = identityPacket.rawBytes
        // MachineName starts at byte 32 (offset 16 in data)
        XCTAssertEqual(identityBytes[32], 0x54) // 'T'
        XCTAssertEqual(identityBytes[33], 0x65) // 'e'
        XCTAssertEqual(identityBytes[34], 0x73) // 's'
        XCTAssertEqual(identityBytes[35], 0x74) // 't'
        XCTAssertEqual(identityBytes[36], 0x4D) // 'M'
        XCTAssertEqual(identityBytes[37], 0x61) // 'a'
        XCTAssertEqual(identityBytes[38], 0x63) // 'c'
        XCTAssertEqual(identityBytes[39], 0x20) // ' ' (padded)
        XCTAssertEqual(identityBytes[63], 0x20) // last byte of machine name
    }
}
