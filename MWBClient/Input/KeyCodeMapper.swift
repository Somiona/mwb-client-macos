import Foundation

enum KeyCodeMapper {
    // Windows VK codes: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
    // macOS keycodes: CGKeyCode values from Events.h

    private static let vkToMac: [UInt16: UInt16] = [
        // Letters
        0x41: 0x00, // A
        0x42: 0x0B, // B
        0x43: 0x08, // C
        0x44: 0x02, // D
        0x45: 0x0E, // E
        0x46: 0x03, // F
        0x47: 0x05, // G
        0x48: 0x04, // H
        0x49: 0x22, // I
        0x4A: 0x26, // J
        0x4B: 0x28, // K
        0x4C: 0x25, // L
        0x4D: 0x2E, // M
        0x4E: 0x2D, // N
        0x4F: 0x1F, // O
        0x50: 0x23, // P
        0x51: 0x0C, // Q
        0x52: 0x0F, // R
        0x53: 0x01, // S
        0x54: 0x11, // T
        0x55: 0x20, // U
        0x56: 0x09, // V
        0x57: 0x0D, // W
        0x58: 0x07, // X
        0x59: 0x10, // Y
        0x5A: 0x06, // Z

        // Numbers
        0x30: 0x1D, // 0
        0x31: 0x12, // 1
        0x32: 0x13, // 2
        0x33: 0x14, // 3
        0x34: 0x15, // 4
        0x35: 0x17, // 5
        0x36: 0x16, // 6
        0x37: 0x1A, // 7
        0x38: 0x1C, // 8
        0x39: 0x19, // 9

        // F keys
        0x70: 0x7A, // F1
        0x71: 0x78, // F2
        0x72: 0x63, // F3
        0x73: 0x76, // F4
        0x74: 0x60, // F5
        0x75: 0x61, // F6
        0x76: 0x62, // F7
        0x77: 0x64, // F8
        0x78: 0x65, // F9
        0x79: 0x6D, // F10
        0x7A: 0x67, // F11
        0x7B: 0x6F, // F12

        // Modifiers
        0x10: 0x38, // VK_SHIFT -> Shift (left)
        0xA0: 0x38, // VK_LSHIFT -> Shift
        0xA1: 0x3C, // VK_RSHIFT -> Right Shift
        0x11: 0x3A, // VK_CONTROL -> Control (left)
        0xA2: 0x3A, // VK_LCONTROL -> Control
        0xA3: 0x3E, // VK_RCONTROL -> Right Control
        0x12: 0x3A, // VK_MENU -> Option (mapped to Control since MWB uses Ctrl for Ctrl)
        0xA4: 0x3A, // VK_LMENU -> Option
        0xA5: 0x3D, // VK_RMENU -> Right Option

        // Navigation
        0x25: 0x7B, // VK_LEFT
        0x26: 0x7E, // VK_UP
        0x27: 0x7C, // VK_RIGHT
        0x28: 0x7D, // VK_DOWN
        0x24: 0x73, // VK_HOME
        0x23: 0x77, // VK_END
        0x21: 0x74, // VK_PRIOR (Page Up)
        0x22: 0x79, // VK_NEXT (Page Down)

        // Special
        0x0D: 0x24, // VK_RETURN
        0x1B: 0x35, // VK_ESCAPE
        0x09: 0x30, // VK_TAB
        0x08: 0x33, // VK_BACK (Backspace)
        0x2E: 0x75, // VK_DELETE
        0x20: 0x31, // VK_SPACE

        // More special
        0x14: 0x39, // VK_CAPITAL (Caps Lock)
        0x2D: 0x72, // VK_INSERT
        0x5B: 0x37, // VK_LWIN -> Command
        0x5C: 0x36, // VK_RWIN -> Right Command

        // Punctuation (US layout)
        0xBD: 0x0A, // VK_OEM_MINUS -> -
        0xBB: 0x18, // VK_OEM_PLUS -> =
        0xDB: 0x21, // VK_OEM_4 -> [
        0xDD: 0x1E, // VK_OEM_6 -> ]
        0xDC: 0x2A, // VK_OEM_5 -> \
        0xBA: 0x29, // VK_OEM_1 -> ;
        0xDE: 0x27, // VK_OEM_7 -> '
        0xC0: 0x32, // VK_OEM_3 -> `
        0xBC: 0x2B, // VK_OEM_COMMA -> ,
        0xBE: 0x2F, // VK_OEM_PERIOD -> .
        0xBF: 0x2C, // VK_OEM_2 -> /

        // Numpad
        0x60: 0x52, // VK_NUMPAD0
        0x61: 0x53, // VK_NUMPAD1
        0x62: 0x54, // VK_NUMPAD2
        0x63: 0x55, // VK_NUMPAD3
        0x64: 0x56, // VK_NUMPAD4
        0x65: 0x57, // VK_NUMPAD5
        0x66: 0x58, // VK_NUMPAD6
        0x67: 0x59, // VK_NUMPAD7
        0x68: 0x5B, // VK_NUMPAD8
        0x69: 0x5C, // VK_NUMPAD9
    ]

    private static let macToVK: [UInt16: UInt16] = {
        var map = [UInt16: UInt16]()
        for (vk, mac) in vkToMac {
            if map[mac] == nil {
                map[mac] = vk
            }
        }
        return map
    }()

    static func vkToMacOS(vkCode: UInt16) -> UInt16? {
        vkToMac[vkCode]
    }

    static func macOSToVK(macOSKeycode: UInt16) -> UInt16? {
        macToVK[macOSKeycode]
    }
}
