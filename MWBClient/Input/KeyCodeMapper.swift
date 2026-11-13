import Carbon.HIToolbox
import Foundation

/// Keyboard layout profile used to translate layout-dependent keys between
/// Windows VK codes and macOS keycodes.
enum KeyboardLayoutProfile {
    /// US ANSI and other layouts where the "/ ?" key is VK_OEM_2 (0xBF).
    case us
    /// Brazilian ABNT2: the "/ ?" key is VK_ABNT_C1 (0xC1), "< >" is
    /// VK_OEM_102 (0xE2) and the numpad decimal is VK_ABNT_C2 (0xC2).
    /// PowerToys forwards these VK codes untouched, so both translation
    /// directions must know the profile to stay interoperable.
    case abnt2
}

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
        0x6A: 0x43, // VK_MULTIPLY -> Keypad *
        0x6B: 0x4E, // VK_ADD -> Keypad +
        0x6D: 0x45, // VK_SUBTRACT -> Keypad -
        0x6E: 0x41, // VK_DECIMAL -> Keypad .
        0x6F: 0x4B, // VK_DIVIDE -> Keypad /

        // Brazilian ABNT2. VK_ABNT_C2 is only emitted by ABNT2 keyboards, so
        // mapping it unconditionally cannot affect other layouts. VK_ABNT_C1
        // ("/ ?") is resolved dynamically in vkToMacOS because its macOS
        // keycode depends on the active layout (see abnt2SlashAndLessKeys).
        0xC2: 0x41, // VK_ABNT_C2 -> Keypad decimal ","
    ]

    private static let baseMacToVK: [UInt16: UInt16] = {
        var map = [UInt16: UInt16]()
        for (vk, mac) in vkToMac {
            if map[mac] == nil {
                map[mac] = vk
            }
        }
        // Reverse-only entries for macOS keys that have no single VK in the
        // forward map. They are never injected today, but must be captured.
        map[0x3B] = 0xA2 // Left Control -> VK_LCONTROL
        map[0x64] = 0xE2 // ISO section ("< >" on ABNT2) -> VK_OEM_102
        return map
    }()

    /// Deterministic choice for macOS keycodes that receive several VK codes:
    /// dictionary iteration order is not stable, so without this table the VK
    /// captured for these keys would vary between launches.
    private static let reverseTieBreak: [UInt16: UInt16] = [
        0x38: 0x10, // Left Shift -> VK_SHIFT (not VK_LSHIFT)
        0x3A: 0xA4, // Left Option -> VK_LMENU (Alt)
        0x2C: 0xBF, // "/ ?" -> VK_OEM_2 (ABNT2 profile overrides to VK_ABNT_C1)
        0x41: 0x6E, // Keypad decimal -> VK_DECIMAL (ABNT2 profile overrides to VK_ABNT_C2)
    ]

    // MARK: - Active layout resolution (ABNT2 keys)

    /// macOS keycodes for the ABNT2 keys, resolved from one keyboard layout.
    private struct LayoutKeys: Sendable {
        var id: String
        /// Keycode that produces "/" unshifted and "?" with Shift.
        var slash: UInt16
        /// Keycode that produces "<" unshifted (ISO section key fallback).
        var less: UInt16
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedLayoutKeys: LayoutKeys?

    /// Keycodes for the ABNT2 "/ ?" and "< >" keys in the ACTIVE macOS layout.
    ///
    /// The keycode cannot be hardcoded: Apple's Brazilian layouts disagree —
    /// "Brasileiro" and "Brasileiro – Pro" place "/ ?" at 0x2C, while
    /// "Brasileiro – ABNT2" places "; :" there and "/ ?" at 0x5E. Hardcoding
    /// 0x2C types "; :" on the ABNT2 layout. The active layout is re-checked
    /// on every call because macOS input sources can differ per app; the
    /// expensive UCKeyTranslate scan only reruns when the layout changes.
    static func abnt2SlashAndLessKeys() -> (slash: UInt16, less: UInt16) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let id = activeLayoutID()
        if let cached = cachedLayoutKeys, cached.id == id {
            return (cached.slash, cached.less)
        }

        let (slash, less) = scanLayoutForKeys()
        mwbInfo(
            MWBLog.input,
            String(
                format: "Resolved ABNT2 keys from layout %@: '/ ?' = 0x%02X, '< >' = 0x%02X",
                id, slash, less))
        cachedLayoutKeys = LayoutKeys(id: id, slash: slash, less: less)
        return (slash, less)
    }

    private static func activeLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "" }
        // Properties follow the Get rule: do not release the returned object.
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Scans the active layout via UCKeyTranslate. Shift state uses the
    /// EventRecord encoding expected by UCKeyTranslate (bit 1 = Shift, i.e. 2).
    private static func scanLayoutForKeys() -> (slash: UInt16, less: UInt16) {
        var slash = UInt16(0x2C) // US ANSI fallback
        var less = UInt16(0x64) // ISO section key fallback
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return (slash, less) }

        // Properties follow the Get rule: do not release the returned object.
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for keycode: UInt16 in 0..<128 {
                let unshifted = translatedCharacter(keycode: keycode, modifier: 0, layout: layout)
                // Prefer the key whose shifted character is "?": excludes the
                // keypad slash (which types "/" in both states).
                if unshifted == "/", translatedCharacter(keycode: keycode, modifier: 2, layout: layout) == "?" {
                    slash = keycode
                    break
                }
            }
            for keycode: UInt16 in 0..<128 {
                if translatedCharacter(keycode: keycode, modifier: 0, layout: layout) == "<" {
                    less = keycode
                    break
                }
            }
        }
        return (slash, less)
    }

    private static func translatedCharacter(
        keycode: UInt16,
        modifier: UInt32,
        layout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout,
            keycode,
            UInt16(kUCKeyActionDisplay),
            modifier,
            UInt32(LMGetKbdType()),
            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// Maps a Windows VK code to a macOS keycode for injection.
    ///
    /// `VK_OEM_102` (the 102nd key) is only translated under the ABNT2 profile,
    /// where it is the "< >" key; other ISO layouts keep it unmapped, matching
    /// the previous behavior for non-ABNT scenarios.
    static func vkToMacOS(vkCode: UInt16, profile: KeyboardLayoutProfile = .us) -> UInt16? {
        if let mac = vkToMac[vkCode] {
            return mac
        }
        switch vkCode {
        case 0xC1:
            // VK_ABNT_C1 is only emitted by ABNT2 keyboards; resolve its
            // keycode from the active layout in every scenario.
            return abnt2SlashAndLessKeys().slash
        case 0xE2 where profile == .abnt2:
            return abnt2SlashAndLessKeys().less
        default:
            return nil
        }
    }

    /// Maps a macOS keycode to a Windows VK code for capture.
    static func macOSToVK(macOSKeycode: UInt16, profile: KeyboardLayoutProfile = .us) -> UInt16? {
        if profile == .abnt2 {
            let keys = abnt2SlashAndLessKeys()
            if macOSKeycode == keys.slash { return 0xC1 } // "/ ?" (VK_OEM_2 does not exist on ABNT2)
            if macOSKeycode == keys.less { return 0xE2 } // "< >"
            if macOSKeycode == 0x41 { return 0xC2 } // Keypad decimal ","
        }
        if let vk = reverseTieBreak[macOSKeycode] {
            return vk
        }
        return baseMacToVK[macOSKeycode]
    }
}
