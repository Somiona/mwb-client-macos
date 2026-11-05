import XCTest
@testable import MWBClient

final class MWBCryptoTests: XCTestCase {
    func testPBKDF2WithSaltMatchesReference() {
        // Reference: python hashlib.pbkdf2_hmac("sha512", b"opencode123!", bytes(range(16)), 100000, 32)
        let salt = [UInt8](0..<16)
        let key = MWBCrypto.deriveKey(securityKey: "opencode123!", salt: salt)
        let expected = "33892b786358734102461bb5420e595fba6e3c099fcee2c41ae89d7c6b9bb61a"
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testEncryptEmitsHeaderOnceAndRoundTrips() {
        let tx = MWBCrypto(securityKey: "MwbEncryptionTestKey1234")
        let rx = MWBCrypto(securityKey: "MwbEncryptionTestKey1234")
        let plain = Data((0..<48).map { UInt8($0 + 1) })

        let wire = tx.encrypt(plain)
        XCTAssertEqual(wire.count, MWBConstants.streamHeaderLength + plain.count)
        rx.startDecryptStream(header: wire.prefix(MWBConstants.streamHeaderLength))
        XCTAssertEqual(rx.decrypt(wire.dropFirst(MWBConstants.streamHeaderLength)), plain)

        // Subsequent writes carry no header and continue the CBC chain.
        let wire2 = tx.encrypt(plain)
        XCTAssertEqual(wire2.count, plain.count)
        XCTAssertEqual(rx.decrypt(wire2), plain)
    }

    func testEachStreamUsesFreshSaltAndIV() {
        let a = MWBCrypto(securityKey: "MwbEncryptionTestKey1234").encrypt(Data(count: 16))
        let b = MWBCrypto(securityKey: "MwbEncryptionTestKey1234").encrypt(Data(count: 16))
        XCTAssertNotEqual(a.prefix(32), b.prefix(32))
    }

    func testMagicHashMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "magic", withExtension: "bin")!
        let expectedData = try Data(contentsOf: url)
        let expectedMagic = expectedData.withUnsafeBytes { $0.load(as: UInt32.self) }

        let crypto = MWBCrypto(securityKey: "opencode123!")
        XCTAssertEqual(crypto.get24BitHash(), expectedMagic, "Magic Hash must match C# 50k SHA512 iterations exactly.")
    }
}
