import XCTest
@testable import MWBClient

final class InputLayerTests: XCTestCase {
    func testMouseRelativeOffsetDecoding() {
        let threshold: Int32 = 100_000
        
        func extract(_ val: Int32) -> Int32 {
            return val >= 0 ? val - threshold : val + threshold
        }
        
        XCTAssertEqual(extract(100005), 5)
        XCTAssertEqual(extract(-99995), 5)
        XCTAssertEqual(extract(100000), 0)
        XCTAssertEqual(extract(-100000), 0)
    }
    
    func testAbsoluteCoordinateScaling() {
        let injection = InputInjection()
        injection.screenBoundsProvider = { CGRect(x: 0, y: 0, width: 1920, height: 1080) }

        let p = injection.mapVirtualToScreen(x: 32767, y: 32767)
        XCTAssertEqual(p.x, 960, accuracy: 1.0, "Absolute coordinates must be scaled from 65535 space.")
    }

    // MARK: - KeyCodeMapper (ABNT2 support)

    func testABNT2SlashKeyInjection() {
        // Windows ABNT2 keyboards report the "/ ?" key as VK_ABNT_C1 (0xC1 = 193).
        // The macOS keycode is resolved from the active layout: Apple's
        // "Brasileiro – ABNT2" places "/ ?" at 0x5E and "; :" at 0x2C, while
        // US ANSI/Brazilian-Pro place "/ ?" at 0x2C — hardcoding either value
        // breaks the other layout.
        let keys = KeyCodeMapper.abnt2SlashAndLessKeys()
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xC1), keys.slash)
        // The ABNT2 numpad decimal (VK_ABNT_C2) is layout-independent.
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xC2), 0x41)
        // The US slash key keeps its original mapping to the same macOS key.
        XCTAssertEqual(KeyCodeMapper.vkToMacOS(vkCode: 0xBF), 0x2C)
    }

    func testABNT2OEM102InjectionFollowsProfile() {
        // VK_OEM_102 (the 102nd key) is only meaningful for layouts that define
        // it; ABNT2 maps it to the "< >" key of the active Mac layout.
        XCTAssertNil(KeyCodeMapper.vkToMacOS(vkCode: 0xE2, profile: .us))
        XCTAssertEqual(
            KeyCodeMapper.vkToMacOS(vkCode: 0xE2, profile: .abnt2),
            KeyCodeMapper.abnt2SlashAndLessKeys().less)
    }

    func testCaptureDirectionRespectsLayoutProfile() {
        // Mac -> Windows must send VK_ABNT_C1 to an ABNT2 machine, because
        // MapVirtualKey(VK_OEM_2) does not resolve on the ABNT2 layout.
        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x2C, profile: .us), 0xBF)
        XCTAssertEqual(
            KeyCodeMapper.macOSToVK(
                macOSKeycode: KeyCodeMapper.abnt2SlashAndLessKeys().slash, profile: .abnt2),
            0xC1)
        XCTAssertEqual(
            KeyCodeMapper.macOSToVK(
                macOSKeycode: KeyCodeMapper.abnt2SlashAndLessKeys().less, profile: .abnt2),
            0xE2)

        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x41, profile: .us), 0x6E)
        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x41, profile: .abnt2), 0xC2)
    }

    func testReverseMapIsDeterministicForCollidingKeys() {
        // Several VK codes share a macOS keycode; the captured VK must be fixed
        // instead of depending on dictionary iteration order.
        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x38), 0x10) // Left Shift
        XCTAssertEqual(KeyCodeMapper.macOSToVK(macOSKeycode: 0x3A), 0xA4) // Option -> Alt
    }

    func testRoundTripCommonKeys() throws {
        let vkCodes: [UInt16] = [0x41, 0x5A, 0x30, 0x0D, 0x20, 0xBF, 0xBD, 0x6E]
        for vk in vkCodes {
            let mac = try XCTUnwrap(KeyCodeMapper.vkToMacOS(vkCode: vk), "VK \(vk) must be mapped")
            XCTAssertEqual(
                KeyCodeMapper.macOSToVK(macOSKeycode: mac), vk,
                "Round trip failed for VK \(vk) (macOS keycode \(mac))")
        }
    }
}
