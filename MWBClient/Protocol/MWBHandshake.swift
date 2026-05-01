import Foundation
import os.log

enum HandshakeState: Equatable {
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
    private(set) var adoptedMachineID: MachineID = .none

    /// Encodes a machine name to 32 bytes using ASCII-compatible encoding,
    /// matching Windows `ASCIIEncoding.ASCII.GetBytes()` behavior.
    /// Non-ASCII characters are replaced with `?` (0x3F).
    /// The result is space-padded (0x20) to exactly 32 bytes.
    static func encodeMachineName(_ name: String) -> Data {
        var bytes = Data(count: 32)
        for i in 0..<32 { bytes[i] = 0x20 }
        var idx = 0
        for scalar in name.unicodeScalars {
            guard idx < 32 else { break }
            bytes[idx] = scalar.value < 128 ? UInt8(scalar.value) : 0x3F
            idx += 1
        }
        return bytes
    }

    mutating func start() {
        state = .exchangingNoise
        receivedChallengeCount = 0
        sentAckCount = 0
    }

    mutating func receiveChallenge(_ packet: MWBPacket, localMachineName: String, localMachineID: MachineID) -> MWBPacket? {
        switch state {
        case .exchangingNoise, .receivingChallenge, .sendingIdentity, .completed:
            break
        default:
            state = .failed("unexpected challenge in state \(state)")
            return nil
        }

        state = .receivingChallenge
        receivedChallengeCount += 1

        var ack = MWBPacket()
        ack.type = PackageType.handshakeAck.rawValue
        ack.id = packet.id
        ack.src = localMachineID
        ack.des = packet.src // Respond back to the server's ID

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

        // Copy machine name into data bytes 16-47 (ASCII-encoded, space-padded to 32 bytes)
        let nameData = Self.encodeMachineName(localMachineName)
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
        adoptedMachineID = .none
    }

    static func makeIdentityPacket(
        machineName: String,
        screenWidth: UInt16,
        screenHeight: UInt16,
        machineID: MachineID
    ) -> MWBPacket {
        var packet = MWBPacket()
        packet.type = PackageType.heartbeatEx.rawValue
        packet.des = MWBConstants.broadcastDestination
        packet.src = machineID

        packet.setDataUInt16(screenWidth, at: 0)
        packet.setDataUInt16(screenHeight, at: 2)

        let nameData = Self.encodeMachineName(machineName)
        if UserDefaults.standard.bool(forKey: "settings.debugLogging") {
            let nameStr = String(data: nameData, encoding: .ascii) ?? "(non-ascii)"
            mwbDebug(Logger.network, "Identity packet: name=\"\(nameStr.trimmingCharacters(in: .whitespaces))\" id=\(machineID) screen=\(screenWidth)x\(screenHeight)")
        }
        var fullData = packet.data
        fullData.replaceSubrange(16..<48, with: nameData)
        packet.data = fullData

        return packet
    }
}
