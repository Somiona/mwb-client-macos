import CommonCrypto
import CryptoKit
import Foundation
import os.log

final class MWBCrypto {
    internal let key: [UInt8]
    private let securityKey: String
    private let initialIV: [UInt8]
    private var encryptIV: [UInt8]
    private var decryptIV: [UInt8]

    /// Sequence counter for correlating encrypt/decrypt calls in logs.
    private var opSequence = 0

    private static let _tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func stamp() -> String {
        _tsFormatter.string(from: Date())
    }

    init(securityKey: String) {
        self.securityKey = securityKey
        mwbDebug(MWBLog.crypto, "Deriving encryption key from security key")

        let salt = MWBConstants.saltString.data(using: .utf16LittleEndian)!
        var derivedKey = [UInt8](repeating: 0, count: MWBConstants.derivedKeyLength)
        let kdfStatus = salt.withUnsafeBytes { saltPtr in
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
        assert(kdfStatus == kCCSuccess, "PBKDF2 key derivation failed with status \(kdfStatus)")
        key = derivedKey

        initialIV = Array(MWBConstants.ivString.utf8.prefix(MWBConstants.ivLength))
        encryptIV = initialIV
        decryptIV = initialIV

        let keyHex = hexPrefix(key, 4)
        let ivHex = hexPrefix(initialIV, 16)
        let saltHex = hexPrefix(Array(salt), 4)
        let now = Self.stamp()
        mwbDebug(MWBLog.crypto, "[\(now)] [CRYPTO-INIT] key(4)=\(keyHex) iv=\(ivHex) salt(4)=\(saltHex)")
    }

    private func hexPrefix(_ bytes: [UInt8], _ count: Int) -> String {
        bytes.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func hexPrefix(_ data: Data, _ count: Int) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func encrypt(_ plaintext: Data) -> Data {
        precondition(plaintext.count % MWBConstants.ivLength == 0, "Plaintext must be block-aligned")

        let seq = opSequence
        opSequence += 1
        let ivBefore = encryptIV

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

        let ivAfterCCCrypt = encryptIV
        if numBytesEncrypted >= MWBConstants.ivLength {
            encryptIV = Array(outBytes.suffix(MWBConstants.ivLength))
        }
        let ivFinal = encryptIV

        if CachedSettings.debugLogging {
            let ptHex = hexPrefix(plaintext, 4)
            let ctHex = hexPrefix(Data(outBytes.prefix(numBytesEncrypted)), 4)
            let ivInHex = hexPrefix(ivBefore, 4)
            let ivAfterHex = hexPrefix(ivAfterCCCrypt, 4)
            let ivFinalHex = hexPrefix(ivFinal, 4)
            let now = Self.stamp()
            mwbDebug(MWBLog.crypto, "[\(now)] [ENC #\(seq)] len=\(plaintext.count) pt(4)=\(ptHex) iv_in=\(ivInHex) iv_afterCC=\(ivAfterHex) iv_final=\(ivFinalHex) ct(4)=\(ctHex) status=\(status)")
        }

        assert(status == kCCSuccess)
        return Data(outBytes.prefix(numBytesEncrypted))
    }

    func decrypt(_ ciphertext: Data) -> Data {
        precondition(ciphertext.count % MWBConstants.ivLength == 0, "Ciphertext must be block-aligned")

        let seq = opSequence
        opSequence += 1
        let ivBefore = decryptIV

        // CBC: save last ciphertext block as next IV before decrypting
        let nextIV = Array(ciphertext.suffix(MWBConstants.ivLength))
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

        let ivAfterCCCrypt = decryptIV
        if ciphertext.count >= MWBConstants.ivLength {
            decryptIV = nextIV
        }
        let ivFinal = decryptIV

        if CachedSettings.debugLogging {
            let ctHex = hexPrefix(ciphertext, 4)
            let ptHex = hexPrefix(Data(outBytes.prefix(numBytesDecrypted)), 4)
            let ivInHex = hexPrefix(ivBefore, 4)
            let ivAfterHex = hexPrefix(ivAfterCCCrypt, 4)
            let ivFinalHex = hexPrefix(ivFinal, 4)
            let now = Self.stamp()
            mwbDebug(MWBLog.crypto, "[\(now)] [DEC #\(seq)] len=\(ciphertext.count) ct(4)=\(ctHex) iv_in=\(ivInHex) iv_afterCC=\(ivAfterHex) iv_final=\(ivFinalHex) pt(4)=\(ptHex) status=\(status)")
        }

        assert(status == kCCSuccess)
        return Data(outBytes.prefix(numBytesDecrypted))
    }

    func reset() {
        let seq = opSequence
        let now = Self.stamp()
        mwbDebug(MWBLog.crypto, "[\(now)] [CRYPTO-RESET] seq=\(seq)")
        opSequence = 0
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
        return (UInt32(bytes[0]) << 23)
             + (UInt32(bytes[1]) << 16)
             + (UInt32(bytes[63]) << 8)
             + UInt32(bytes[2])
    }
}
