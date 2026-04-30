import XCTest
@testable import MWBClient

final class MWBCryptoTests: XCTestCase {

    func testPBKDF2DerivationMatchesCSharp() throws {
        // C# "TestKey123!" derived key with UTF-16LE InitialIV salt, 50k iterations
        let myKey = "TestKey123!"
        let expectedKeyHex = "d6dc0290d1544b522d482cb4d6cfe878627a575539def1c85ff99854ffa74b05"
        
        let crypto = MWBCrypto(securityKey: myKey)
        let derivedKeyHex = crypto.key.map { String(format: "%02x", $0) }.joined()
        
        XCTAssertEqual(derivedKeyHex, expectedKeyHex, "Derived key should match C# output exactly.")
    }

    func testAES256CBCEncryptionMatchesCSharp() throws {
        // We know for "TestKey123!" IV is 31383434363734343037333730393535
        // Plaintext "Hello, MWB!" (UTF-16LE) -> C# encrypts it with PaddingMode.Zeros
        let myKey = "TestKey123!"
        let plaintextString = "Hello, MWB!"
        var plaintextData = plaintextString.data(using: .utf16LittleEndian)!
        
        // Pad to block size of 16 (AES block size)
        let remainder = plaintextData.count % 16
        if remainder != 0 {
            plaintextData.append(contentsOf: [UInt8](repeating: 0, count: 16 - remainder))
        }
        
        let expectedCiphertextHex = "ad2e632ebd0e752d72f8606a425f8a14eb45071ddf162095ad3f4923ba2903f1"
        
        let crypto = MWBCrypto(securityKey: myKey)
        let ciphertext = crypto.encrypt(plaintextData)
        let ciphertextHex = ciphertext.map { String(format: "%02x", $0) }.joined()
        
        XCTAssertEqual(ciphertextHex, expectedCiphertextHex, "Ciphertext should match C# AES Zero Padding output.")
    }

    func testMagicHashMatchesCSharp() throws {
        let key = "TestKey123!"
        let expectedMagicHash: UInt32 = 1746535194
        
        let crypto = MWBCrypto(securityKey: key)
        let magicHash = crypto.get24BitHash()
        XCTAssertEqual(magicHash, expectedMagicHash, "Magic Hash should match C# output exactly.")
    }
}