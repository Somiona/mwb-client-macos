import Foundation

enum WMMouseMessage: UInt32 {
    case mouseMove = 0x0200
    case lButtonDown = 0x0201
    case lButtonUp = 0x0202
    case rButtonDown = 0x0204
    case rButtonUp = 0x0205
    case mButtonDown = 0x0207
    case mButtonUp = 0x0208
    case mouseWheel = 0x020A
    case mouseHWheel = 0x020E
}

struct MouseData {
    var x: Int32
    var y: Int32
    var wheelDelta: Int32
    var dwFlags: UInt32

    var wmMessage: WMMouseMessage? {
        WMMouseMessage(rawValue: dwFlags)
    }

    static let dataOffset = 0

    init(x: Int32 = 0, y: Int32 = 0, wheelDelta: Int32 = 0, dwFlags: UInt32 = 0) {
        self.x = x
        self.y = y
        self.wheelDelta = wheelDelta
        self.dwFlags = dwFlags
    }

    init(from packet: MWBPacket) {
        self.x = Int32(bitPattern: packet.dataUInt32(at: 0))
        self.y = Int32(bitPattern: packet.dataUInt32(at: 4))
        self.wheelDelta = Int32(bitPattern: packet.dataUInt32(at: 8))
        self.dwFlags = packet.dataUInt32(at: 12)
    }

    func write(to packet: inout MWBPacket) {
        packet.setDataUInt32(UInt32(bitPattern: x), at: 0)
        packet.setDataUInt32(UInt32(bitPattern: y), at: 4)
        packet.setDataUInt32(UInt32(bitPattern: wheelDelta), at: 8)
        packet.setDataUInt32(dwFlags, at: 12)
    }
}
