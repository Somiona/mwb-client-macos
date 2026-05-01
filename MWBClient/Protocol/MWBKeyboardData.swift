import Foundation

enum LLKHFFlag: UInt32 {
    case extended = 0x01
    case injected = 0x10
    case altDown = 0x20
    case up = 0x80
}

struct KeyboardData {
    var vkCode: UInt16
    var flags: UInt32

    var isKeyUp: Bool {
        (flags & LLKHFFlag.up.rawValue) != 0
    }

    var isExtended: Bool {
        (flags & LLKHFFlag.extended.rawValue) != 0
    }

    init(vkCode: UInt16 = 0, flags: UInt32 = 0) {
        self.vkCode = vkCode
        self.flags = flags
    }

    init(from packet: MWBPacket) {
        // Protocol KEYBDDATA: wVk (int/UInt32) at data[8..11], dwFlags (int/UInt32) at data[12..15]
        let rawVk = packet.dataUInt32(at: 8)
        self.vkCode = UInt16(truncatingIfNeeded: rawVk)
        self.flags = packet.dataUInt32(at: 12)
    }

    func write(to packet: inout MWBPacket) {
        // Protocol KEYBDDATA: wVk (int/UInt32) at data[8..11], dwFlags (int/UInt32) at data[12..15]
        // This overlaps with MOUSEDATA.WheelDelta and MOUSEDATA.dwFlags, matching PowerToys DATA.cs.
        packet.setDataUInt32(UInt32(vkCode), at: 8)
        packet.setDataUInt32(flags, at: 12)
    }
}
