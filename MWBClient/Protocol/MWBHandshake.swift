import Foundation

enum HandshakeState {
    case idle
    case exchangingNoise
    case receivingChallenge
    case sendingAcknowledge
    case sendingIdentity
    case completed
    case failed(String)
}

struct HandshakeHandler {
    private(set) var state: HandshakeState = .idle
    private(set) var receivedChallengeCount = 0
    private(set) var sentAckCount = 0
    private(set) var adoptedMachineID: UInt32 = 0

    mutating func start() {
        state = .exchangingNoise
        receivedChallengeCount = 0
        sentAckCount = 0
    }

    mutating func receiveChallenge(_ packet: MWBPacket, localMachineName: String) -> MWBPacket? {
        switch state {
        case .exchangingNoise, .receivingChallenge, .sendingIdentity, .completed:
            break
        default:
            state = .failed("unexpected challenge in state \(state)")
            return nil
        }

        state = .receivingChallenge
        receivedChallengeCount += 1

        if packet.des != 0 {
            adoptedMachineID = packet.des
        }

        var ack = MWBPacket()
        ack.type = PackageType.handshakeAck.rawValue
        ack.id = packet.id
        ack.src = 0
        ack.des = packet.des

        // Flip Machine1-4 fields (first 16 bytes of data, four UInt32s at offsets 0, 4, 8, 12)
        let challengeData = packet.data
        var responseData = Data(count: MWBConstants.dataFieldSize)

        for fieldOffset in [0, 4, 8, 12] {
            let value = challengeData.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: fieldOffset, as: UInt32.self).littleEndian
            }
            let flipped = ~value
            responseData.withUnsafeMutableBytes {
                $0.storeBytes(of: flipped.littleEndian, toByteOffset: fieldOffset, as: UInt32.self)
            }
        }

        // Copy machine name into data bytes 16-47 (space-padded to 32 bytes)
        var nameData = Data(count: 32)
        let nameBytes = Array(localMachineName.prefix(32).utf8)
        for i in 0..<nameBytes.count {
            nameData[i] = nameBytes[i]
        }
        for i in nameBytes.count..<32 {
            nameData[i] = 0x20
        }
        responseData.replaceSubrange(16..<48, with: nameData)

        ack.data = responseData

        sentAckCount += 1
        return ack
    }

    mutating func completeIfReady() -> Bool {
        guard receivedChallengeCount >= MWBConstants.handshakeIterationCount else { return false }
        state = .sendingIdentity
        return true
    }

    mutating func completeIdentity() {
        state = .completed
    }

    mutating func reset() {
        state = .idle
        receivedChallengeCount = 0
        sentAckCount = 0
        adoptedMachineID = 0
    }

    static func makeIdentityPacket(
        machineName: String,
        screenWidth: UInt16,
        screenHeight: UInt16,
        machineID: UInt32
    ) -> MWBPacket {
        var packet = MWBPacket()
        packet.type = PackageType.heartbeatEx.rawValue
        packet.des = MWBConstants.broadcastDestination
        packet.src = machineID

        packet.setDataUInt16(screenWidth, at: 0)
        packet.setDataUInt16(screenHeight, at: 2)

        var nameData = Data(count: 32)
        let nameBytes = Array(machineName.prefix(32).utf8)
        for i in 0..<nameBytes.count {
            nameData[i] = nameBytes[i]
        }
        for i in nameBytes.count..<32 {
            nameData[i] = 0x20 // space padding
        }
        var fullData = packet.data
        fullData.replaceSubrange(16..<48, with: nameData)
        packet.data = fullData

        return packet
    }
}
