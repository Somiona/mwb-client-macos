import Foundation

enum MWBConstants {
    static let inputPort: UInt16 = 15101
    static let clipboardPort: UInt16 = 15100

    static let smallPacketSize = 32
    static let bigPacketSize = 64
    static let dataFieldSize = 48

    static let reconnectDelay: TimeInterval = 5.0
    static let heartbeatInterval: TimeInterval = 2.0
    static let clipboardPollInterval: TimeInterval = 0.5

    static let handshakeIterationCount = 10
    static let noiseSize = 16

    static let pbkdf2Iterations = 50_000
    static let derivedKeyLength = 32
    static let ivLength = 16
    static let saltString = "18446744073709551615"
    static let ivString = "1844674407370955"
    static let sha512Rounds = 50_001

    static let virtualDesktopMax: Int32 = 65535
    static let broadcastDestination: UInt32 = 0xFF
}
