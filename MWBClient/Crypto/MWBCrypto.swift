import CommonCrypto
import CryptoKit
import Foundation

final class MWBCrypto {
    private let key: [UInt8]
    private let securityKey: String
    private let initialIV: [UInt8]
    private var encryptIV: [UInt8]
    private var decryptIV: [UInt8]

    init(securityKey: String) {
        self.securityKey = securityKey

        let salt = MWBConstants.saltString.data(using: .utf16LittleEndian)!
        var derivedKey = [UInt8](repeating: 0, count: MWBConstants.derivedKeyLength)
        salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                securityKey,
                securityKey.utf8.count,
                saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                UInt32(MWBConstants.pbkdf2Iterations),
                &derivedKey,
                MWBConstants.derivedKeyLength
            )
        }
        key = derivedKey

        initialIV = Array(MWBConstants.ivString.utf8.prefix(MWBConstants.ivLength))
        encryptIV = initialIV
        decryptIV = initialIV
    }

    func encrypt(_ plaintext: Data) -> Data {
        precondition(plaintext.count % MWBConstants.ivLength == 0, "Plaintext must be block-aligned")

        var inBytes = Array(plaintext)
        var outBytes = [UInt8](repeating: 0, count: inBytes.count)
        var numBytesEncrypted: Int = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(),
            key, key.count,
            &encryptIV,
            &inBytes, inBytes.count,
            &outBytes, outBytes.count,
            &numBytesEncrypted
        )
        assert(status == kCCSuccess)

        if numBytesEncrypted >= MWBConstants.ivLength {
            encryptIV = Array(outBytes.suffix(MWBConstants.ivLength))
        }
        return Data(outBytes.prefix(numBytesEncrypted))
    }

    func decrypt(_ ciphertext: Data) -> Data {
        precondition(ciphertext.count % MWBConstants.ivLength == 0, "Ciphertext must be block-aligned")

        let previousIV = Array(ciphertext.suffix(MWBConstants.ivLength))
        var inBytes = Array(ciphertext)
        var outBytes = [UInt8](repeating: 0, count: inBytes.count)
        var numBytesDecrypted: Int = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(),
            key, key.count,
            &decryptIV,
            &inBytes, inBytes.count,
            &outBytes, outBytes.count,
            &numBytesDecrypted
        )
        assert(status == kCCSuccess)

        if ciphertext.count >= MWBConstants.ivLength {
            decryptIV = previousIV
        }
        return Data(outBytes.prefix(numBytesDecrypted))
    }

    func reset() {
        encryptIV = initialIV
        decryptIV = initialIV
    }

    func get24BitHash() -> UInt32 {
        var input = Data(count: MWBConstants.smallPacketSize)
        let keyBytes = Array(securityKey.utf8.prefix(MWBConstants.smallPacketSize))
        for i in 0..<keyBytes.count {
            input[i] = keyBytes[i]
        }

        var hashValue = SHA512.hash(data: input)

        for _ in 0..<50_000 {
            hashValue = SHA512.hash(data: Data(hashValue))
        }

        let bytes = Data(hashValue)
        return UInt32(bytes[0]) << 23
             | UInt32(bytes[1]) << 16
             | UInt32(bytes[63]) << 8
             | UInt32(bytes[2])
    }
}
