import Foundation

enum MWBConstants {
    // Port layout (matching Windows MWB, TcpPort default = 15100):
    //   TcpPort     (15100) = Clipboard server
    //   TcpPort + 1 (15101) = Message/input server
    //   Client connects to TcpPort + 1 for input, TcpPort for clipboard
    static let inputPort: UInt16 = 15101
    static let clipboardPort: UInt16 = 15100

    static let smallPacketSize = 32
    static let bigPacketSize = 64
    static let dataFieldSize = 48

    static let reconnectDelay: TimeInterval = 5.0
    static let heartbeatInterval: TimeInterval = 2.0
    static let heartbeatTimeout: TimeInterval = 1500.0 // 25 minutes (1,500,000 ms)
    static let heartbeatCheckInterval: UInt64 = 60_000_000_000 // 60 seconds in nanoseconds
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
