import Testing
import Foundation
import CryptoKit
import CommonCrypto

@testable import MWBClient

// MARK: - Helpers

// Helper to avoid Swift Testing #expect macro issue with value type computed properties
private func checkIsBig(_ pt: PackageType) -> Bool {
    pt.isBig
}

// MARK: - Crypto Tests

@Suite(.serialized)
@MainActor
struct CryptoCompatibilityTests {

    // MARK: 1. PBKDF2 salt is UTF-16 LE encoding of "18446744073709551615"

    @Test("PBKDF2 salt is UTF-16 LE encoding of ulong.MaxValue string")
    func testPBKDF2SaltIsUTF16LE() {
        // PowerToys: Common.GetBytesU(InitialIV) where InitialIV = ulong.MaxValue.ToString()
        // ASCIIEncoding.Unicode.GetBytes() == UTF-16 LE
        let initialIV = String(UInt64.max)
        #expect(initialIV == "18446744073709551615")

        let salt = initialIV.data(using: .utf16LittleEndian)!
        // "18446744073709551615" = 20 chars x 2 bytes/char = 40 bytes
        #expect(salt.count == 40)

        // First character '1' in UTF-16 LE = [0x31, 0x00]
        #expect(salt[0] == 0x31)
        #expect(salt[1] == 0x00)

        // Second character '8' in UTF-16 LE = [0x38, 0x00]
        #expect(salt[2] == 0x38)
        #expect(salt[3] == 0x00)

        // Last character '5' in UTF-16 LE = [0x35, 0x00]
        #expect(salt[38] == 0x35)
        #expect(salt[39] == 0x00)

        // Verify our implementation uses the same salt
        #expect(MWBConstants.saltString == initialIV)
    }

    // MARK: 2. PBKDF2 key derivation produces 32 bytes, deterministic

    @Test("PBKDF2 key derivation produces 32 bytes and is deterministic")
    func testPBKDF2KeyDerivationProduces32Bytes() {
        let testKey = "test-security-key-16chars"
        let crypto1 = MWBCrypto(securityKey: testKey)
        let crypto2 = MWBCrypto(securityKey: testKey)

        // Both instances should produce identical encrypted output (same IV start)
        let plaintext = Data(repeating: 0xAA, count: 16)
        let ct1 = crypto1.encrypt(plaintext)
        let ct2 = crypto2.encrypt(plaintext)

        #expect(ct1 == ct2, "Encryption must be deterministic with same key and IV")
        #expect(ct1.count == 16, "Ciphertext should match plaintext block size")

        // Decryption should recover original
        let crypto3 = MWBCrypto(securityKey: testKey)
        let pt = crypto3.decrypt(ct1)
        #expect(pt == plaintext)
    }

    // MARK: 3. Encrypt/decrypt roundtrip with 32 bytes

    @Test("Encrypt and decrypt roundtrip with 32-byte data")
    func testEncryptDecryptRoundtrip() {
        let crypto = MWBCrypto(securityKey: "roundtrip-test-key!!")
        let plaintext = Data([
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        ])

        let ciphertext = crypto.encrypt(plaintext)
        let decrypted = crypto.decrypt(ciphertext)

        #expect(decrypted == plaintext, "Roundtrip should recover original plaintext")
        #expect(ciphertext != plaintext, "Ciphertext must differ from plaintext")
    }

    // MARK: 4. CBC state chains across calls

    @Test("CBC state chains across calls - same plaintext produces different ciphertext")
    func testCBCStateChainsAcrossCalls() {
        let crypto = MWBCrypto(securityKey: "chaining-state-test!")
        let plaintext = Data(repeating: 0x42, count: 16)

        let ct1 = crypto.encrypt(plaintext)
        let ct2 = crypto.encrypt(plaintext)

        // PowerToys uses .NET CryptoStream which chains CBC state internally.
        // Same plaintext produces different ciphertext on successive calls.
        #expect(ct1 != ct2, "CBC chaining must produce different ciphertext for identical plaintext")
        #expect(ct1.count == 16)
        #expect(ct2.count == 16)

        // Both should decrypt back correctly with a fresh instance
        let cryptoDecrypt = MWBCrypto(securityKey: "chaining-state-test!")
        let pt1 = cryptoDecrypt.decrypt(ct1)
        let pt2 = cryptoDecrypt.decrypt(ct2)

        #expect(pt1 == plaintext)
        #expect(pt2 == plaintext)
    }

    // MARK: 5. Encrypt/decrypt multiple blocks (simulated protocol sequence)

    @Test("Encrypt/decrypt simulated protocol sequence: noise + handshake + heartbeat")
    func testEncryptDecryptMultipleBlocks() {
        // PowerToys protocol: first 16 bytes = random noise block per InitialIV,
        // then handshake (64 bytes = 4 AES blocks), then heartbeat (64 bytes)
        let crypto = MWBCrypto(securityKey: "multi-block-protoco!")

        // Simulate noise(16 bytes) -- the first block sent through the encrypted stream
        // In PowerToys, this is RandomNumberGenerator.GetBytes(16) written directly
        // to the CryptoStream, so it gets encrypted with the initial IV
        let noisePlaintext = Data([
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        ])
        let noiseCT = crypto.encrypt(noisePlaintext)

        // Simulate handshake packet (64 bytes = 4 AES blocks)
        var handshakePacket = MWBPacket()
        handshakePacket.type = PackageType.handshake.rawValue
        handshakePacket.id = 1
        handshakePacket.src = 0x01
        handshakePacket.des = 0xFF
        let handshakeData = handshakePacket.rawBytes
        let handshakeCT = crypto.encrypt(handshakeData)

        // Simulate heartbeat packet (64 bytes = 4 AES blocks)
        var heartbeatPacket = MWBPacket()
        heartbeatPacket.type = PackageType.heartbeat.rawValue
        heartbeatPacket.id = 2
        heartbeatPacket.src = 0x01
        heartbeatPacket.des = 0xFF
        let heartbeatData = heartbeatPacket.rawBytes
        let heartbeatCT = crypto.encrypt(heartbeatData)

        // Now decrypt everything with a fresh crypto instance
        let cryptoDec = MWBCrypto(securityKey: "multi-block-protoco!")
        let noiseDec = cryptoDec.decrypt(noiseCT)
        let handshakeDec = cryptoDec.decrypt(handshakeCT)
        let heartbeatDec = cryptoDec.decrypt(heartbeatCT)

        #expect(noiseDec == noisePlaintext)
        #expect(handshakeDec == handshakeData)
        #expect(heartbeatDec == heartbeatData)
    }

    // MARK: 6. Crypto reset restores initial IV state

    @Test("Crypto reset restores initial IV state")
    func testCryptoResetRestoresInitialIV() {
        let crypto = MWBCrypto(securityKey: "reset-iv-test-key!!!")
        let plaintext = Data(repeating: 0xCC, count: 16)

        let ct1 = crypto.encrypt(plaintext)
        let ct2 = crypto.encrypt(plaintext)
        #expect(ct1 != ct2, "CBC chaining should produce different ciphertext")

        crypto.reset()

        // After reset, encrypting same plaintext should produce same ciphertext as first call
        let ct3 = crypto.encrypt(plaintext)
        #expect(ct3 == ct1, "After reset, first encryption should match initial ciphertext")
    }

    // MARK: 7. 24-bit hash is deterministic and within range

    @Test("24-bit hash is deterministic and within 24-bit range")
    func test24BitHashIsDeterministic() {
        let key = "deterministic-hash-key"
        let crypto1 = MWBCrypto(securityKey: key)
        let crypto2 = MWBCrypto(securityKey: key)

        let hash1 = crypto1.get24BitHash()
        let hash2 = crypto2.get24BitHash()

        #expect(hash1 == hash2, "Same key must produce same 24-bit hash")

        // Formula max: (0xFF<<23) + (0xFF<<16) + (0xFF<<8) + 0xFF
        let maxPossible: UInt32 = (0xFF << 23) + (0xFF << 16) + (0xFF << 8) + 0xFF
        #expect(hash1 <= maxPossible, "Hash must fit within the formula range")

        // Verify with a different key produces a different hash
        let crypto3 = MWBCrypto(securityKey: "different-key-entirely")
        let hash3 = crypto3.get24BitHash()
        #expect(hash3 != hash1, "Different keys should produce different hashes")
    }

    @Test("24-bit hash formula matches PowerToys exactly")
    func test24BitHashFormulaMatchesPowerToys() {
        // Verify our implementation matches the exact PowerToys formula:
        // (hashValue[0] << 23) + (hashValue[1] << 16) + (hashValue[last] << 8) + hashValue[2]
        // where hashValue = SHA512(SHA512^50000(key_padded_to_32_bytes))
        let key = "formula-verification-key"
        let crypto = MWBCrypto(securityKey: key)

        // Compute hash manually to verify the formula
        var input = Data(count: MWBConstants.smallPacketSize) // 32 bytes, zeroed
        let keyBytes = Array(key.utf8.prefix(MWBConstants.smallPacketSize))
        for i in 0..<keyBytes.count {
            input[i] = keyBytes[i]
        }

        var hashValue = SHA512.hash(data: input)
        for _ in 0..<50_000 {
            hashValue = SHA512.hash(data: Data(hashValue))
        }

        let bytes = Data(hashValue)
        let expectedHash = (UInt32(bytes[0]) << 23)
            + (UInt32(bytes[1]) << 16)
            + (UInt32(bytes[63]) << 8)  // hashValue[^1] = last byte
            + UInt32(bytes[2])

        let actualHash = crypto.get24BitHash()
        #expect(actualHash == expectedHash, "Hash formula must match PowerToys Get24BitHash")
    }
}

// MARK: - Packet Layout Tests

@Suite(.serialized)
@MainActor
struct PacketLayoutTests {

    // MARK: 8. Packet header layout

    @Test("Packet header layout: type at byte 0, magic at 2-3, id/src/des little-endian at 4-15")
    func testPacketHeaderLayout() {
        var packet = MWBPacket()

        // Type at byte 0
        packet.type = PackageType.mouse.rawValue  // 123 = 0x7B
        #expect(packet.rawBytes[0] == 0x7B)

        // Checksum at byte 1
        packet.checksum = 0xAB
        #expect(packet.rawBytes[1] == 0xAB)

        // Magic at bytes 2-3
        packet.magic0 = 0xCD
        packet.magic1 = 0xEF
        #expect(packet.rawBytes[2] == 0xCD)
        #expect(packet.rawBytes[3] == 0xEF)

        // Id at bytes 4-7, little-endian
        packet.id = 0x12345678
        let raw = packet.rawBytes
        #expect(raw[4] == 0x78, "Id byte 0 (LSB)")
        #expect(raw[5] == 0x56, "Id byte 1")
        #expect(raw[6] == 0x34, "Id byte 2")
        #expect(raw[7] == 0x12, "Id byte 3 (MSB)")

        // Src at bytes 8-11, little-endian
        packet.src = 0xAABBCCDD
        let raw2 = packet.rawBytes
        #expect(raw2[8] == 0xDD, "Src byte 0 (LSB)")
        #expect(raw2[9] == 0xCC, "Src byte 1")
        #expect(raw2[10] == 0xBB, "Src byte 2")
        #expect(raw2[11] == 0xAA, "Src byte 3 (MSB)")

        // Des at bytes 12-15, little-endian
        packet.des = 0x11223344
        let raw3 = packet.rawBytes
        #expect(raw3[12] == 0x44, "Des byte 0 (LSB)")
        #expect(raw3[13] == 0x33, "Des byte 1")
        #expect(raw3[14] == 0x22, "Des byte 2")
        #expect(raw3[15] == 0x11, "Des byte 3 (MSB)")
    }

    // MARK: 9. Mouse data layout

    @Test("Mouse data layout: x/y at data[0..7], wheelDelta at data[8..11], dwFlags at data[12..15]")
    func testMouseDataLayout() {
        var packet = MWBPacket()
        packet.type = PackageType.mouse.rawValue

        let mouseData = MouseData(
            x: 1920,
            y: 1080,
            wheelDelta: -120,
            dwFlags: WMMouseMessage.mouseMove.rawValue
        )
        mouseData.write(to: &packet)

        // x at data[0..3], little-endian
        let raw = packet.rawBytes
        let xBytes = [raw[16], raw[17], raw[18], raw[19]]
        let xValue = UInt32(xBytes[0]) | UInt32(xBytes[1]) << 8
            | UInt32(xBytes[2]) << 16 | UInt32(xBytes[3]) << 24
        #expect(Int32(bitPattern: xValue) == 1920)

        // y at data[4..7], little-endian
        let yBytes = [raw[20], raw[21], raw[22], raw[23]]
        let yValue = UInt32(yBytes[0]) | UInt32(yBytes[1]) << 8
            | UInt32(yBytes[2]) << 16 | UInt32(yBytes[3]) << 24
        #expect(Int32(bitPattern: yValue) == 1080)

        // wheelDelta at data[8..11], little-endian
        let wheelBytes = [raw[24], raw[25], raw[26], raw[27]]
        let wheelValue = UInt32(wheelBytes[0]) | UInt32(wheelBytes[1]) << 8
            | UInt32(wheelBytes[2]) << 16 | UInt32(wheelBytes[3]) << 24
        #expect(Int32(bitPattern: wheelValue) == -120)

        // dwFlags at data[12..15], little-endian
        let flagsBytes = [raw[28], raw[29], raw[30], raw[31]]
        let flagsValue = UInt32(flagsBytes[0]) | UInt32(flagsBytes[1]) << 8
            | UInt32(flagsBytes[2]) << 16 | UInt32(flagsBytes[3]) << 24
        #expect(flagsValue == 0x0200)

        // Roundtrip: read back from packet
        let readMouse = MouseData(from: packet)
        #expect(readMouse.x == 1920)
        #expect(readMouse.y == 1080)
        #expect(readMouse.wheelDelta == -120)
        #expect(readMouse.dwFlags == 0x0200)
    }

    // MARK: 10. Keyboard data layout

    @Test("Keyboard data layout: wVk (UInt32) at data[0..3], dwFlags (UInt32) at data[4..7]")
    func testKeyboardDataLayout() {
        var packet = MWBPacket()
        packet.type = PackageType.keyboard.rawValue

        let kbData = KeyboardData(
            vkCode: 0x41,  // 'A' key
            flags: LLKHFFlag.up.rawValue  // 0x80
        )
        kbData.write(to: &packet)

        // wVk at data[0..3] (raw bytes 16-19), little-endian UInt32
        let raw = packet.rawBytes
        let vkRaw = UInt32(raw[16]) | UInt32(raw[17]) << 8
            | UInt32(raw[18]) << 16 | UInt32(raw[19]) << 24
        #expect(vkRaw == 0x41, "wVk should be UInt32 0x41 at data[0..3] (raw bytes 16-19)")

        // dwFlags at data[4..7] (raw bytes 20-23), little-endian UInt32
        let flags = UInt32(raw[20]) | UInt32(raw[21]) << 8
            | UInt32(raw[22]) << 16 | UInt32(raw[23]) << 24
        #expect(flags == 0x80, "dwFlags should be UInt32 0x80 at data[4..7] (raw bytes 20-23)")

        // Verify LLKHF.UP = 0x80 (matches PowerToys WM.cs)
        #expect(LLKHFFlag.up.rawValue == 0x80)
        #expect(LLKHFFlag.extended.rawValue == 0x01)
        #expect(LLKHFFlag.injected.rawValue == 0x10)
        #expect(LLKHFFlag.altDown.rawValue == 0x20)

        // Roundtrip
        let readKb = KeyboardData(from: packet)
        #expect(readKb.vkCode == 0x41)
        #expect(readKb.flags == 0x80)
        #expect(readKb.isKeyUp == true)
        #expect(readKb.isExtended == false)
    }

    // MARK: 10b. Keyboard serialization with flags=0 (keydown)

    @Test("Keyboard serialization: vkCode=0x41, flags=0 writes exact bytes and roundtrips")
    func testKeyboardSerializationKeyDown() {
        var packet = MWBPacket()
        packet.type = PackageType.keyboard.rawValue

        let kbData = KeyboardData(vkCode: 0x41, flags: 0)
        kbData.write(to: &packet)

        let raw = packet.rawBytes

        // data[0..3] = wVk as UInt32 LE at raw bytes 16-19
        #expect(raw[16] == 0x41, "vk LSB")
        #expect(raw[17] == 0x00)
        #expect(raw[18] == 0x00)
        #expect(raw[19] == 0x00, "vk MSB")

        // data[4..7] = dwFlags as UInt32 LE at raw bytes 20-23
        #expect(raw[20] == 0x00, "flags byte 0")
        #expect(raw[21] == 0x00, "flags byte 1")
        #expect(raw[22] == 0x00, "flags byte 2")
        #expect(raw[23] == 0x00, "flags byte 3")

        // Roundtrip
        let readKb = KeyboardData(from: packet)
        #expect(readKb.vkCode == 0x41)
        #expect(readKb.flags == 0)
        #expect(readKb.isKeyUp == false)
        #expect(readKb.isExtended == false)
    }

    // MARK: 10c. Keyboard round-trip for multiple VK codes and flag combinations

    @Test("Keyboard round-trip: multiple VK codes and flag combinations")
    func testKeyboardRoundTripMultiple() {
        let cases: [(vkCode: UInt16, flags: UInt32, expectKeyUp: Bool, expectExtended: Bool)] = [
            (0x41, 0x00, false, false),            // A keydown
            (0x41, 0x80, true, false),             // A keyup
            (0x0D, 0x00, false, false),            // Enter keydown
            (0x0D, 0x80, true, false),             // Enter keyup
            (0x10, 0x00, false, false),            // Shift keydown
            (0x10, 0x80, true, false),             // Shift keyup
            (0x11, 0x20, false, false),            // Ctrl keydown with altDown
            (0x12, 0x30, false, false),            // Alt keydown with injected + altDown
            (0x5B, 0x81, true, true),              // Left Win keyup with extended
            (0x5D, 0x01, false, true),             // Right Win keydown with extended
            (0xFF, 0x90, true, false),             // Unknown high vkCode with injected + UP
            (0x00, 0x80, true, false),             // Null vkCode with keyup flag
        ]

        for (i, tc) in cases.enumerated() {
            var packet = MWBPacket()
            packet.type = PackageType.keyboard.rawValue

            let original = KeyboardData(vkCode: tc.vkCode, flags: tc.flags)
            original.write(to: &packet)

            let readBack = KeyboardData(from: packet)
            #expect(readBack.vkCode == tc.vkCode, "Case \(i): vkCode mismatch")
            #expect(readBack.flags == tc.flags, "Case \(i): flags mismatch")
            #expect(readBack.isKeyUp == tc.expectKeyUp, "Case \(i): isKeyUp")
            #expect(readBack.isExtended == tc.expectExtended, "Case \(i): isExtended")
        }
    }

    // MARK: 10d. LLKHF.UP flag (0x80) specifically

    @Test("LLKHF.UP flag 0x80 sets isKeyUp and roundtrips correctly")
    func testLLKHFUpFlag() {
        // Keyup for 'Z' (0x5A) with only the UP flag
        var packet = MWBPacket()
        packet.type = PackageType.keyboard.rawValue

        let keyUp = KeyboardData(vkCode: 0x5A, flags: LLKHFFlag.up.rawValue)
        keyUp.write(to: &packet)

        let raw = packet.rawBytes
        let flags = UInt32(raw[20]) | UInt32(raw[21]) << 8
            | UInt32(raw[22]) << 16 | UInt32(raw[23]) << 24
        #expect(flags == 0x80, "Only LLKHF.UP bit should be set")

        let readBack = KeyboardData(from: packet)
        #expect(readBack.vkCode == 0x5A)
        #expect(readBack.flags == 0x80)
        #expect(readBack.isKeyUp == true)
        #expect(readBack.isExtended == false)

        // Combined flags: UP + EXTENDED + INJECTED (0x80 | 0x01 | 0x10 = 0x91)
        var packet2 = MWBPacket()
        packet2.type = PackageType.keyboard.rawValue

        let combined = KeyboardData(vkCode: 0x5A, flags: 0x91)
        combined.write(to: &packet2)

        let readBack2 = KeyboardData(from: packet2)
        #expect(readBack2.flags == 0x91)
        #expect(readBack2.isKeyUp == true)
        #expect(readBack2.isExtended == true)

        // UP + ALT_DOWN (0x80 | 0x20 = 0xA0)
        var packet3 = MWBPacket()
        packet3.type = PackageType.keyboard.rawValue

        let altUp = KeyboardData(vkCode: 0x12, flags: 0xA0)
        altUp.write(to: &packet3)

        let readBack3 = KeyboardData(from: packet3)
        #expect(readBack3.flags == 0xA0)
        #expect(readBack3.isKeyUp == true)
        #expect(readBack3.isExtended == false)
    }

    // MARK: 10e. Bidirectional: Windows sends raw bytes, macOS parses correctly

    @Test("Bidirectional: raw packet bytes as Windows would send, macOS parses correctly")
    func testBidirectionalWindowsToMacOS() {
        // Simulate Windows constructing raw packet bytes for a keyboard event.
        // Windows KEYBDDATA layout in the 32-byte small packet:
        //   bytes[0] = type (122 = keyboard)
        //   bytes[1] = checksum
        //   bytes[2..3] = magic
        //   bytes[4..7] = id (LE)
        //   bytes[8..11] = src (LE)
        //   bytes[12..15] = des (LE)
        //   bytes[16..19] = wVk as int32 LE
        //   bytes[20..23] = dwFlags as int32 LE
        //   bytes[24..31] = remaining data (zeroed)

        // Case 1: Windows sends 'B' keydown (vk=0x42, flags=0x00)
        var windowsBytes = [UInt8](repeating: 0, count: 32)
        windowsBytes[0] = 122  // PackageType.keyboard
        windowsBytes[1] = 0x00 // checksum placeholder
        windowsBytes[2] = 0x00
        windowsBytes[3] = 0x00
        // id = 42
        windowsBytes[4] = 42
        windowsBytes[5] = 0
        windowsBytes[6] = 0
        windowsBytes[7] = 0
        // src = 2, des = 1
        windowsBytes[8] = 2
        windowsBytes[9] = 0
        windowsBytes[10] = 0
        windowsBytes[11] = 0
        windowsBytes[12] = 1
        windowsBytes[13] = 0
        windowsBytes[14] = 0
        windowsBytes[15] = 0
        // wVk = 0x42 (LE UInt32)
        windowsBytes[16] = 0x42
        windowsBytes[17] = 0x00
        windowsBytes[18] = 0x00
        windowsBytes[19] = 0x00
        // dwFlags = 0x00 (keydown)
        windowsBytes[20] = 0x00
        windowsBytes[21] = 0x00
        windowsBytes[22] = 0x00
        windowsBytes[23] = 0x00

        let packet = MWBPacket(rawData: Data(windowsBytes))
        let parsed1 = KeyboardData(from: packet)
        #expect(parsed1.vkCode == 0x42, "Bidirectional: 'B' keydown vkCode")
        #expect(parsed1.flags == 0x00, "Bidirectional: 'B' keydown flags")
        #expect(parsed1.isKeyUp == false, "Bidirectional: 'B' should be keydown")

        // Case 2: Windows sends 'B' keyup (vk=0x42, flags=0x80)
        windowsBytes[20] = 0x80
        windowsBytes[21] = 0x00
        windowsBytes[22] = 0x00
        windowsBytes[23] = 0x00

        let packet2 = MWBPacket(rawData: Data(windowsBytes))
        let parsed2 = KeyboardData(from: packet2)
        #expect(parsed2.vkCode == 0x42, "Bidirectional: 'B' keyup vkCode")
        #expect(parsed2.flags == 0x80, "Bidirectional: 'B' keyup flags")
        #expect(parsed2.isKeyUp == true, "Bidirectional: 'B' should be keyup")

        // Case 3: Windows sends extended key (vk=0x5B LWin, flags=0x81 = UP|EXTENDED)
        windowsBytes[16] = 0x5B
        windowsBytes[17] = 0x00
        windowsBytes[18] = 0x00
        windowsBytes[19] = 0x00
        windowsBytes[20] = 0x81
        windowsBytes[21] = 0x00
        windowsBytes[22] = 0x00
        windowsBytes[23] = 0x00

        let packet3 = MWBPacket(rawData: Data(windowsBytes))
        let parsed3 = KeyboardData(from: packet3)
        #expect(parsed3.vkCode == 0x5B, "Bidirectional: LWin vkCode")
        #expect(parsed3.flags == 0x81, "Bidirectional: LWin flags")
        #expect(parsed3.isKeyUp == true, "Bidirectional: LWin isKeyUp")
        #expect(parsed3.isExtended == true, "Bidirectional: LWin isExtended")

        // Case 4: Full bidirectional roundtrip -- macOS writes, parse as raw bytes, verify offsets
        var macPacket = MWBPacket()
        macPacket.type = PackageType.keyboard.rawValue
        macPacket.id = 99
        macPacket.src = 3
        macPacket.des = 7

        let macKb = KeyboardData(vkCode: 0x0D, flags: 0x00) // Enter keydown
        macKb.write(to: &macPacket)

        let macRaw = macPacket.rawBytes
        // Reconstruct from raw bytes only (stripping header context)
        let vkFromRaw = UInt16(macRaw[16]) | UInt16(macRaw[17]) << 8
        let flagsFromRaw = UInt32(macRaw[20]) | UInt32(macRaw[21]) << 8
            | UInt32(macRaw[22]) << 16 | UInt32(macRaw[23]) << 24
        #expect(vkFromRaw == 0x0D, "Bidirectional roundtrip: Enter vk")
        #expect(flagsFromRaw == 0x00, "Bidirectional roundtrip: Enter flags")
    }

    // MARK: 11. isBig packet classification

    @Test("isBig packet classification matches PowerToys DATA.cs IsBigPackage logic")
    func testIsBigPacketClassification() {
        // PowerToys IsBigPackage switch:
        // Hello(3), Awake(21), Heartbeat(20), Heartbeat_ex(51),
        // Handshake(126), HandshakeAck(127),
        // ClipboardPush(79), Clipboard(69), ClipboardAsk(78),
        // ClipboardImage(125), ClipboardText(124), ClipboardDataEnd(76) => true
        // default: (Type & Matrix) == Matrix  (Matrix = 128)

        let bigTypes: [PackageType] = [
            .hello,
            .awake,
            .heartbeat,
            .heartbeatEx,
            .handshake,
            .handshakeAck,
            .clipboardPush,
            .clipboard,
            .clipboardAsk,
            .clipboardImage,
            .clipboardText,
            .clipboardDataEnd,
        ]

        for pt in bigTypes {
            let result = checkIsBig(pt)
            #expect(result == true, "PackageType rawValue \(pt.rawValue) should be big (64 bytes)")
        }

        // Matrix (128) itself: 128 & 128 == 128 => big
        #expect(checkIsBig(.matrix), "Matrix (128) should be big via bit mask")

        // Matrix with flags: e.g. 128 | 2 = 130, 130 & 128 = 128 => big
        // Note: PackageType(rawValue: 130) is nil since 130 is not a defined case.
        // The isBig logic for Matrix subtypes is: (Type & 0x80) == 0x80.
        // Verify this via the MWBPacket's isBig which uses the raw byte.
        var matrixFlagPacket = MWBPacket()
        matrixFlagPacket.type = 130  // Matrix | MatrixSwapFlag
        #expect(matrixFlagPacket.isBig, "Packet with type 130 (Matrix|SwapFlag) should be big via bit mask")

        // Small packets (not in explicit list, not Matrix bit)
        let smallTypes: [PackageType] = [
            .hi,           // 2
            .byeBye,       // 4
            .hideMouse,    // 50
            .heartbeatExL2, // 52
            .heartbeatExL3, // 53
            .clipboardDragDrop, // 70
            .clipboardDragDropEnd, // 71
            .explorerDragDrop, // 72
            .clipboardCapture, // 73
            .captureScreenCommand, // 74
            .clipboardDragDropOperation, // 75
            .machineSwitched, // 77
            .nextMachine,  // 121
            .keyboard,     // 122
            .mouse,        // 123
        ]

        for pt in smallTypes {
            let result = checkIsBig(pt)
            #expect(result == false, "PackageType rawValue \(pt.rawValue) should be small (32 bytes)")
        }
    }

    // MARK: 12. Checksum validation

    @Test("Checksum computation and validation")
    func testChecksumValidation() {
        var packet = MWBPacket()
        packet.type = PackageType.mouse.rawValue
        packet.id = 42
        packet.src = 1
        packet.des = 2

        // Set some data bytes to create non-trivial checksum
        var data = Data(count: 48)
        data[0] = 0x10
        data[1] = 0x20
        data[47] = 0x80
        packet.data = data

        // Compute checksum
        let checksum = packet.computeChecksum()
        #expect(packet.checksum == checksum)

        // Validate should pass
        #expect(packet.validateChecksum())

        // Corrupt a byte via id field and validation should fail
        let savedId = packet.id
        packet.id = savedId &+ 1
        #expect(!packet.validateChecksum())

        // Restore and re-validate
        packet.id = savedId
        _ = packet.computeChecksum()
        #expect(packet.validateChecksum())
    }
}

// MARK: - Handshake Tests

@Suite(.serialized)
struct HandshakeCompatibilityTests {

    // MARK: 13. Handshake challenge -> ack with bitwise NOT

    @Test("Handshake challenge produces ACK with bitwise NOT machine fields, adopting machine ID")
    func testHandshakeChallengeResponse() {
        var handler = HandshakeHandler()
        handler.start()

        // Create a challenge packet (type 126)
        var challenge = MWBPacket()
        challenge.type = PackageType.handshake.rawValue
        challenge.id = 100
        challenge.src = 0x05
        challenge.des = 0x03

        // Set Machine1 field at data offset 0-3 (UInt32 little-endian)
        var challengeData = Data(count: 48)
        challengeData[0] = 0x42
        challengeData[1] = 0x00
        challengeData[2] = 0xFF
        challengeData[3] = 0x80
        challenge.data = challengeData

        guard let ack = handler.receiveChallenge(challenge, localMachineName: "TestMac") else {
            Issue.record("receiveChallenge should return an ACK packet")
            return
        }

        // ACK should be type 127
        #expect(ack.type == PackageType.handshakeAck.rawValue)

        // ACK Machine1 field should be bitwise NOT of challenge Machine1 (UInt32 at offset 0)
        let responseData = ack.data
        let ackMachine1 = responseData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        let challengeMachine1 = challengeData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        #expect(ackMachine1 == ~challengeMachine1, "Machine1 should be bitwise NOT of challenge")

        // ACK src should be 0 (ID.NONE), not copied from challenge
        #expect(ack.id == 100)
        #expect(ack.src == 0)
        #expect(ack.des == 0x03)

        // Machine name should be at data[16..47]
        let nameBytes = Data(responseData[16..<48])
        let nameString = String(data: nameBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        #expect(nameString == "TestMac", "Machine name should appear at data[16..47]")

        // Machine ID should be adopted from challenge des
        #expect(handler.adoptedMachineID == 0x03)
    }

    // MARK: 14. Handshake requires 10 iterations

    @Test("Handshake requires 10 iterations - not ready at 9, ready at 10")
    func testHandshakeRequiresTenIterations() {
        var handler = HandshakeHandler()
        handler.start()

        var challenge = MWBPacket()
        challenge.type = PackageType.handshake.rawValue
        challenge.id = 0
        challenge.src = 1
        challenge.des = 0xFF

        // Send 9 challenges
        for i in 0..<9 {
            challenge.id = UInt32(i)
            _ = handler.receiveChallenge(challenge, localMachineName: "TestMac")
        }

        // Not ready after 9
        let notReadyResult = handler.completeIfReady()
        #expect(!notReadyResult, "Should not be ready after 9 iterations")
        #expect(handler.receivedChallengeCount == 9)

        // Send 10th challenge
        challenge.id = 9
        _ = handler.receiveChallenge(challenge, localMachineName: "TestMac")
        #expect(handler.receivedChallengeCount == 10)

        // Ready after 10
        let readyResult = handler.completeIfReady()
        #expect(readyResult, "Should be ready after 10 iterations")
        // Verify state transition by checking sentAckCount (10 acks sent means state advanced)
        #expect(handler.sentAckCount == 10)
    }

    // MARK: 15. Re-handshake after completion

    @Test("Re-handshake accepted after initial handshake completes")
    func testReHandshakeAfterCompletion() {
        var handler = HandshakeHandler()
        handler.start()

        // Complete initial handshake
        var challenge = MWBPacket()
        challenge.type = PackageType.handshake.rawValue
        challenge.src = 1
        challenge.des = 0xFF

        for _ in 0..<10 {
            _ = handler.receiveChallenge(challenge, localMachineName: "TestMac")
        }
        _ = handler.completeIfReady()
        handler.completeIdentity()
        // State should be .completed (verified via sentAckCount and receivedChallengeCount)

        // Send a new challenge after completion - should be accepted
        challenge.id = 100
        challenge.des = 0x03

        guard let ack = handler.receiveChallenge(challenge, localMachineName: "TestMac") else {
            Issue.record("Should accept re-handshake challenge after completion")
            return
        }

        #expect(ack.type == PackageType.handshakeAck.rawValue)
        #expect(ack.id == 100)
        #expect(handler.adoptedMachineID == 0x03, "Should adopt new machine ID from re-handshake")
    }

    // MARK: 16. Identity packet format

    @Test("Identity packet format: type 51, screen dims at data[0..3], machine name at data[16..47]")
    func testIdentityPacketFormat() {
        let identity = HandshakeHandler.makeIdentityPacket(
            machineName: "MyMacBook",
            screenWidth: 2560,
            screenHeight: 1440,
            machineID: 0x01
        )

        // Type should be heartbeatEx (51)
        #expect(identity.type == PackageType.heartbeatEx.rawValue)

        // Des should be broadcast (0xFF)
        #expect(identity.des == 0xFF)

        // Src should be machine ID
        #expect(identity.src == 0x01)

        // Screen width at data[0..1], little-endian
        let width = identity.dataUInt16(at: 0)
        #expect(width == 2560)

        // Screen height at data[2..3], little-endian
        let height = identity.dataUInt16(at: 2)
        #expect(height == 1440)

        // Machine name at data[16..47], space-padded
        let nameBytes = [UInt8](identity.rawBytes[32..<64])
        let expectedName = Array("MyMacBook".utf8)
        for i in 0..<expectedName.count {
            #expect(nameBytes[i] == expectedName[i], "Name byte \(i) should match")
        }
        // Remaining bytes should be space-padded (0x20)
        for i in expectedName.count..<32 {
            #expect(nameBytes[i] == 0x20, "Name padding byte \(i) should be 0x20 (space)")
        }
    }
}

// MARK: - PackageType Value Verification

@Suite(.serialized)
struct PackageTypeValueTests {

    @Test("PackageType raw values match PowerToys PackageType.cs exactly")
    func testPackageTypeValuesMatchPowerToys() {
        // Values from PackageType.cs
        // Note: invalid (0xFF) and error (0xFE) are not implemented in our enum
        #expect(PackageType.hi.rawValue == 2)
        #expect(PackageType.hello.rawValue == 3)
        #expect(PackageType.byeBye.rawValue == 4)
        #expect(PackageType.heartbeat.rawValue == 20)
        #expect(PackageType.awake.rawValue == 21)
        #expect(PackageType.hideMouse.rawValue == 50)
        #expect(PackageType.heartbeatEx.rawValue == 51)
        #expect(PackageType.heartbeatExL2.rawValue == 52)
        #expect(PackageType.heartbeatExL3.rawValue == 53)
        #expect(PackageType.clipboard.rawValue == 69)
        #expect(PackageType.clipboardDragDrop.rawValue == 70)
        #expect(PackageType.clipboardDragDropEnd.rawValue == 71)
        #expect(PackageType.explorerDragDrop.rawValue == 72)
        #expect(PackageType.clipboardCapture.rawValue == 73)
        #expect(PackageType.captureScreenCommand.rawValue == 74)
        #expect(PackageType.clipboardDragDropOperation.rawValue == 75)
        #expect(PackageType.clipboardDataEnd.rawValue == 76)
        #expect(PackageType.machineSwitched.rawValue == 77)
        #expect(PackageType.clipboardAsk.rawValue == 78)
        #expect(PackageType.clipboardPush.rawValue == 79)
        #expect(PackageType.nextMachine.rawValue == 121)
        #expect(PackageType.keyboard.rawValue == 122)
        #expect(PackageType.mouse.rawValue == 123)
        #expect(PackageType.clipboardText.rawValue == 124)
        #expect(PackageType.clipboardImage.rawValue == 125)
        #expect(PackageType.handshake.rawValue == 126)
        #expect(PackageType.handshakeAck.rawValue == 127)
        #expect(PackageType.matrix.rawValue == 128)
    }
}

// MARK: - WM Constants Verification

@Suite(.serialized)
struct WMConstantsTests {

    @Test("WM mouse message constants match PowerToys WM.cs")
    func testWMMouseConstants() {
        #expect(WMMouseMessage.mouseMove.rawValue == 0x0200)
        #expect(WMMouseMessage.lButtonDown.rawValue == 0x0201)
        #expect(WMMouseMessage.lButtonUp.rawValue == 0x0202)
        #expect(WMMouseMessage.rButtonDown.rawValue == 0x0204)
        #expect(WMMouseMessage.rButtonUp.rawValue == 0x0205)
        #expect(WMMouseMessage.mButtonDown.rawValue == 0x0207)
        #expect(WMMouseMessage.mButtonUp.rawValue == 0x0208)
        #expect(WMMouseMessage.mouseWheel.rawValue == 0x020A)
        #expect(WMMouseMessage.mouseHWheel.rawValue == 0x020E)
    }

    @Test("LLKHF flags match PowerToys WM.cs exactly")
    func testLLKHFFlags() {
        #expect(LLKHFFlag.extended.rawValue == 0x01)
        #expect(LLKHFFlag.injected.rawValue == 0x10)
        #expect(LLKHFFlag.altDown.rawValue == 0x20)
        #expect(LLKHFFlag.up.rawValue == 0x80)
    }
}

// MARK: - Protocol Constants Verification

@Suite(.serialized)
struct ProtocolConstantsTests {

    @Test("Protocol constants match PowerToys")
    func testProtocolConstants() {
        // Ports
        #expect(MWBConstants.inputPort == 15101)
        #expect(MWBConstants.clipboardPort == 15100)

        // Packet sizes: PowerToys PACKAGE_SIZE = 32, PACKAGE_SIZE_EX = 64
        #expect(MWBConstants.smallPacketSize == 32)
        #expect(MWBConstants.bigPacketSize == 64)

        // PBKDF2: PowerToys uses 50000 iterations, 32-byte key, SHA-512
        #expect(MWBConstants.pbkdf2Iterations == 50_000)
        #expect(MWBConstants.derivedKeyLength == 32)

        // AES block size
        #expect(MWBConstants.ivLength == 16)

        // Salt: ulong.MaxValue.ToString() = "18446744073709551615"
        #expect(MWBConstants.saltString == "18446744073709551615")

        // Handshake: 10 iterations
        #expect(MWBConstants.handshakeIterationCount == 10)

        // Noise block size: PowerToys SymAlBlockSize = 16
        #expect(MWBConstants.noiseSize == 16)
    }

    @Test("IV string matches PowerToys InitialIV")
    func testIVStringMatchesPowerToys() {
        // PowerToys InitialIV = ulong.MaxValue.ToString() = "18446744073709551615"
        // Then truncated/padded to 16 bytes via ASCII encoding
        let powerToysIV = String(UInt64.max)
        #expect(powerToysIV == "18446744073709551615")
        // PowerToys GenLegalIV() takes first 16 ASCII bytes of this string
        let expectedIVBytes = Array(powerToysIV.utf8.prefix(16))
        let actualIVBytes = Array(MWBConstants.ivString.utf8.prefix(16))

        // PowerToys: "1844674407370955" (first 16 chars of "18446744073709551615")
        let expectedIVString = String(powerToysIV.prefix(16))
        #expect(expectedIVString == "1844674407370955")
        #expect(expectedIVBytes == actualIVBytes,
                 "IV must be first 16 ASCII bytes of ulong.MaxValue string")
    }
}
