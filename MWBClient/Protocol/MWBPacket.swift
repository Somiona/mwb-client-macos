import Foundation

enum PackageType: UInt8 {
    case hi = 2              // #future: session greeting
    case hello = 3
    case byeBye = 4          // #future: session disconnect
    case heartbeat = 20
    case awake = 21
    case hideMouse = 50      // #future: cursor visibility control
    case heartbeatEx = 51
    case heartbeatExL2 = 52
    case heartbeatExL3 = 53
    case clipboard = 69
    case clipboardDragDrop = 70          // #future: drag-drop clipboard
    case clipboardDragDropEnd = 71       // #future
    case explorerDragDrop = 72           // #future
    case clipboardCapture = 73           // #future
    case captureScreenCommand = 74       // #future
    case clipboardDragDropOperation = 75 // #future
    case clipboardDataEnd = 76
    case machineSwitched = 77            // #future: multi-machine switching
    case clipboardAsk = 78
    case clipboardPush = 79
    case nextMachine = 121               // #future: multi-machine switching
    case keyboard = 122
    case mouse = 123
    case clipboardText = 124
    case clipboardImage = 125
    case handshake = 126
    case handshakeAck = 127
    case matrix = 128

    var isBig: Bool {
        switch self {
        case .hello, .awake, .heartbeat, .heartbeatEx,
             .handshake, .handshakeAck,
             .clipboardPush, .clipboard, .clipboardAsk,
             .clipboardImage, .clipboardText, .clipboardDataEnd:
            return true
        default:
            return (rawValue & 0x80) != 0
        }
    }
}

struct MWBPacket {
    private var bytes: Data

    init() {
        bytes = Data(count: MWBConstants.bigPacketSize)
    }

    init(rawData: Data) {
        bytes = Data(count: MWBConstants.bigPacketSize)
        let copyCount = min(rawData.count, MWBConstants.bigPacketSize)
        bytes.replaceSubrange(0..<copyCount, with: rawData.prefix(copyCount))
    }

    // MARK: - Header fields

    var type: UInt8 {
        get { bytes[0] }
        set { bytes[0] = newValue }
    }

    var packageType: PackageType? {
        get { PackageType(rawValue: type) }
        set { type = newValue?.rawValue ?? 0 }
    }

    var checksum: UInt8 {
        get { bytes[1] }
        set { bytes[1] = newValue }
    }

    var magic0: UInt8 {
        get { bytes[2] }
        set { bytes[2] = newValue }
    }

    var magic1: UInt8 {
        get { bytes[3] }
        set { bytes[3] = newValue }
    }

    var id: UInt32 {
        get { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian } }
        set { withUnsafeMutableBytes { $0.storeBytes(of: newValue.littleEndian, toByteOffset: 4, as: UInt32.self) } }
    }

    var src: UInt32 {
        get { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian } }
        set { withUnsafeMutableBytes { $0.storeBytes(of: newValue.littleEndian, toByteOffset: 8, as: UInt32.self) } }
    }

    var des: UInt32 {
        get { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian } }
        set { withUnsafeMutableBytes { $0.storeBytes(of: newValue.littleEndian, toByteOffset: 12, as: UInt32.self) } }
    }

    // MARK: - Data field (offset 16, 48 bytes)

    var data: Data {
        get { Data(bytes[16..<(16 + MWBConstants.dataFieldSize)]) }
        set {
            let clamped = newValue.prefix(MWBConstants.dataFieldSize)
            bytes.replaceSubrange(16..<(16 + clamped.count), with: clamped)
        }
    }

    func dataUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= MWBConstants.dataFieldSize)
        return bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16 + offset, as: UInt32.self).littleEndian
        }
    }

    mutating func setDataUInt32(_ value: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= MWBConstants.dataFieldSize)
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: 16 + offset, as: UInt32.self)
        }
    }

    func dataUInt16(at offset: Int) -> UInt16 {
        precondition(offset >= 0 && offset + 2 <= MWBConstants.dataFieldSize)
        return bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16 + offset, as: UInt16.self).littleEndian
        }
    }

    mutating func setDataUInt16(_ value: UInt16, at offset: Int) {
        precondition(offset >= 0 && offset + 2 <= MWBConstants.dataFieldSize)
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: 16 + offset, as: UInt16.self)
        }
    }

    // MARK: - Packet size

    var isBig: Bool {
        if let pt = packageType { return pt.isBig }
        return (type & 0x80) != 0
    }

    var transmittedSize: Int {
        isBig ? MWBConstants.bigPacketSize : MWBConstants.smallPacketSize
    }

    var transmittedData: Data {
        bytes.prefix(transmittedSize)
    }

    var rawBytes: Data {
        bytes
    }

    // MARK: - Checksum

    mutating func computeChecksum() -> UInt8 {
        let end = isBig ? MWBConstants.bigPacketSize : MWBConstants.smallPacketSize
        var sum: UInt8 = 0
        for i in 2..<end {
            sum &+= bytes[i]
        }
        checksum = sum
        return sum
    }

    func validateChecksum() -> Bool {
        let end = isBig ? MWBConstants.bigPacketSize : MWBConstants.smallPacketSize
        var sum: UInt8 = 0
        for i in 2..<end {
            sum &+= bytes[i]
        }
        return sum == checksum
    }

    // MARK: - Magic

    mutating func setMagic(_ hash24: UInt32) {
        magic0 = UInt8(hash24 >> 16)
        magic1 = UInt8((hash24 >> 8) & 0xFF)
    }

    func validateMagic(_ hash24: UInt32) -> Bool {
        return magic0 == UInt8(hash24 >> 16) && magic1 == UInt8((hash24 >> 8) & 0xFF)
    }

    private mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeMutableBytes(body)
    }
}
