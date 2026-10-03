import XCTest
@testable import MWBClient

final class MWBCryptoTests: XCTestCase {
    func testPBKDF2DerivationMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "key", withExtension: "bin")!
        let expectedKey = try Data(contentsOf: url)

        let crypto = MWBCrypto(securityKey: "opencode123!")
        let salt = (0..<UInt8(16)).map { $0 }
        XCTAssertEqual(crypto.deriveKey(salt: salt), [UInt8](expectedKey),
                       "Derived key must match C# PBKDF2 (100,000 iterations, raw 16-byte salt) exactly.")
    }

    func testMagicHashMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "magic", withExtension: "bin")!
        let expectedData = try Data(contentsOf: url)
        let expectedMagic = expectedData.withUnsafeBytes { $0.load(as: UInt32.self) }

        let crypto = MWBCrypto(securityKey: "opencode123!")
        XCTAssertEqual(crypto.get24BitHash(), expectedMagic, "Magic Hash must match C# 50k SHA512 iterations exactly.")
    }

    // Mirrors PowerToys EncryptionTests: every connection must negotiate a
    // fresh random salt + IV header.
    func testOutboundHeaderUniquePerCall() {
        let crypto = MWBCrypto(securityKey: "opencode123!")
        let first = crypto.makeOutboundHeader()
        let second = crypto.makeOutboundHeader()
        XCTAssertEqual(first.count, MWBConstants.streamHeaderSize)
        XCTAssertEqual(second.count, MWBConstants.streamHeaderSize)
        XCTAssertNotEqual(first, second, "Per-connection salt+IV headers must be unique")
    }

    // Mirrors PowerToys EncryptionTests encrypt -> decrypt round-tripping:
    // one side's outbound header must configure the peer's inbound cipher.
    func testRoundTripWithPeerHeaders() {
        let sender = MWBCrypto(securityKey: "opencode123!")
        let receiver = MWBCrypto(securityKey: "opencode123!")

        let header = sender.makeOutboundHeader()
        receiver.processInboundHeader(header)

        let plaintext = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let ciphertext = sender.encrypt(plaintext)
        XCTAssertEqual(receiver.decrypt(ciphertext), plaintext)
    }
}
