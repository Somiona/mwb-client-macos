import Foundation

enum LLKHFFlag: UInt32 {
    case extended = 0x01
    case injected = 0x10
    case altDown = 0x20
    case up = 0x80
}

struct KeyboardData {
    var vkCode: UInt16
    var scanCode: UInt16
    var flags: UInt32

    var isKeyUp: Bool {
        (flags & LLKHFFlag.up.rawValue) != 0
    }

    var isExtended: Bool {
        (flags & LLKHFFlag.extended.rawValue) != 0
    }

    static let dataOffset = 8

    init(vkCode: UInt16 = 0, scanCode: UInt16 = 0, flags: UInt32 = 0) {
        self.vkCode = vkCode
        self.scanCode = scanCode
        self.flags = flags
    }

    init(from packet: MWBPacket) {
        self.vkCode = packet.dataUInt16(at: 8)
        self.scanCode = packet.dataUInt16(at: 10)
        self.flags = packet.dataUInt32(at: 12)
    }

    func write(to packet: inout MWBPacket) {
        packet.setDataUInt16(vkCode, at: 8)
        packet.setDataUInt16(scanCode, at: 10)
        packet.setDataUInt32(flags, at: 12)
    }
}
