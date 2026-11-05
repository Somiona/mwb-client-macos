import CommonCrypto
import CryptoKit
import Foundation
import os.log

final class MWBCrypto {
    /// Per-direction state. PowerToys (>= 0.100, PR #48742) sends a cleartext header
    /// (16-byte random salt + 16-byte random IV) at the start of each direction of the
    /// stream; the AES key for that direction is PBKDF2(securityKey, salt).
    internal private(set) var encryptKey: [UInt8]?
    internal private(set) var decryptKey: [UInt8]?
    private let securityKey: String
    private var encryptIV: [UInt8] = []
    private var decryptIV: [UInt8] = []
    private var pendingEncryptHeader: Data?

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
        mwbDebug(MWBLog.crypto, "Crypto ready (per-connection salt/IV, \(MWBConstants.pbkdf2Iterations) PBKDF2 iterations)")
    }

    /// Derives the AES-256 key for a direction: PBKDF2-HMAC-SHA512(securityKey, salt).
    static func deriveKey(securityKey: String, salt: [UInt8]) -> [UInt8] {
        var derivedKey = [UInt8](repeating: 0, count: MWBConstants.derivedKeyLength)
        let kdfStatus = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            securityKey,
            securityKey.utf8.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            UInt32(MWBConstants.pbkdf2Iterations),
            &derivedKey,
            MWBConstants.derivedKeyLength
        )
        assert(kdfStatus == kCCSuccess, "PBKDF2 key derivation failed with status \(kdfStatus)")
        return derivedKey
    }

    /// Generates this side's random salt+IV header and derives the encryption key.
    /// The header is prepended to the first ciphertext returned by `encrypt`.
    private func startEncryptStream() {
        var header = [UInt8](repeating: 0, count: MWBConstants.streamHeaderLength)
        let rc = SecRandomCopyBytes(kSecRandomDefault, header.count, &header)
        assert(rc == errSecSuccess)
        let salt = Array(header[0..<MWBConstants.saltLength])
        encryptIV = Array(header[MWBConstants.saltLength...])
        encryptKey = Self.deriveKey(securityKey: securityKey, salt: salt)
        pendingEncryptHeader = Data(header)
        let now = Self.stamp()
        mwbDebug(MWBLog.crypto, "[\(now)] [CRYPTO-INIT] tx header: salt(4)=\(hexPrefix(salt, 4)) iv(4)=\(hexPrefix(encryptIV, 4)) key(4)=\(hexPrefix(encryptKey!, 4))")
    }

    /// Configures decryption from the 32-byte cleartext header received from the peer.
    /// Must be called once per connection before the first `decrypt`.
    func startDecryptStream(header: Data) {
        precondition(header.count == MWBConstants.streamHeaderLength, "Stream header must be \(MWBConstants.streamHeaderLength) bytes")
        let bytes = Array(header)
        let salt = Array(bytes[0..<MWBConstants.saltLength])
        decryptIV = Array(bytes[MWBConstants.saltLength...])
        decryptKey = Self.deriveKey(securityKey: securityKey, salt: salt)
        let now = Self.stamp()
        mwbDebug(MWBLog.crypto, "[\(now)] [CRYPTO-INIT] rx header: salt(4)=\(hexPrefix(salt, 4)) iv(4)=\(hexPrefix(decryptIV, 4)) key(4)=\(hexPrefix(decryptKey!, 4))")
    }

    private func hexPrefix(_ bytes: [UInt8], _ count: Int) -> String {
        bytes.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func hexPrefix(_ data: Data, _ count: Int) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func encrypt(_ plaintext: Data) -> Data {
        precondition(plaintext.count % MWBConstants.ivLength == 0, "Plaintext must be block-aligned")

        if encryptKey == nil { startEncryptStream() }
        let key = encryptKey!

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
        var result = Data(outBytes.prefix(numBytesEncrypted))
        if let header = pendingEncryptHeader {
            result = header + result
            pendingEncryptHeader = nil
        }
        return result
    }

    func decrypt(_ ciphertext: Data) -> Data {
        precondition(ciphertext.count % MWBConstants.ivLength == 0, "Ciphertext must be block-aligned")

        guard let key = decryptKey else {
            preconditionFailure("startDecryptStream(header:) must be called before decrypt")
        }

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
        encryptKey = nil
        decryptKey = nil
        encryptIV = []
        decryptIV = []
        pendingEncryptHeader = nil
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
