import XCTest
@testable import MWBClient

final class MWBCryptoTests: XCTestCase {
    func testPBKDF2DerivationMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "key", withExtension: "bin", subdirectory: "Fixtures")!
        let expectedKey = try Data(contentsOf: url)

        let crypto = MWBCrypto(securityKey: "opencode123!")
        XCTAssertEqual(crypto.key, [UInt8](expectedKey), "Derived key must match C# PBKDF2 exactly.")
    }

    func testMagicHashMatchesGoldenFile() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "magic", withExtension: "bin", subdirectory: "Fixtures")!
        let expectedData = try Data(contentsOf: url)
        let expectedMagic = expectedData.withUnsafeBytes { $0.load(as: UInt32.self) }

        let crypto = MWBCrypto(securityKey: "opencode123!")
        XCTAssertEqual(crypto.get24BitHash(), expectedMagic, "Magic Hash must match C# 50k SHA512 iterations exactly.")
    }
}
