import Foundation
import CryptoKit
import CommonCrypto

enum SpecterCryptoError: Error { case pbkdf2, badFrame, counter }

// MARK: - Key derivation primitives (match server/crypto.py)

func pbkdf2SHA256(password: String, salt: Data, iterations: Int = 210_000, keyLen: Int = 32) -> Data {
    var derived = Data(count: keyLen)
    let pw = Data(password.utf8)
    let status: Int32 = derived.withUnsafeMutableBytes { dOut in
        salt.withUnsafeBytes { sIn in
            pw.withUnsafeBytes { pIn in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pIn.baseAddress!.assumingMemoryBound(to: Int8.self), pw.count,
                    sIn.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    dOut.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLen)
            }
        }
    }
    precondition(status == kCCSuccess, "PBKDF2 failed")
    return derived
}

func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                     salt: salt, info: info, outputByteCount: length)
    return key.withUnsafeBytes { Data($0) }
}

func hmacSHA256(key: Data, msg: Data) -> Data {
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
    return Data(mac)
}

// MARK: - AES-256-GCM framed channel (match server SecureChannel)

final class SecureChannel {
    private let enc: SymmetricKey
    private let dec: SymmetricKey
    private let sendPrefix: Data   // 4 bytes
    private let recvPrefix: Data   // 4 bytes
    private var sendCtr: UInt64 = 0
    private var recvCtr: UInt64 = 0
    private let lock = NSLock()

    init(sendKey: Data, recvKey: Data, sendPrefix: Data, recvPrefix: Data) {
        self.enc = SymmetricKey(data: sendKey)
        self.dec = SymmetricKey(data: recvKey)
        self.sendPrefix = sendPrefix
        self.recvPrefix = recvPrefix
    }

    func seal(_ plaintext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let ctr = sendCtr
        var nonceData = sendPrefix
        var be = ctr.bigEndian
        withUnsafeBytes(of: &be) { nonceData.append(contentsOf: $0) }
        let box = try AES.GCM.seal(plaintext, using: enc, nonce: AES.GCM.Nonce(data: nonceData))
        var wire = Data()
        withUnsafeBytes(of: &be) { wire.append(contentsOf: $0) }  // 8-byte counter on the wire
        wire.append(box.ciphertext)
        wire.append(box.tag)
        sendCtr &+= 1
        return wire
    }

    func open(_ wire: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard wire.count >= 8 + 16 else { throw SpecterCryptoError.badFrame }
        let base = wire.startIndex
        let ctrData = wire.subdata(in: base ..< base + 8)
        var ctr: UInt64 = 0; for b in ctrData { ctr = ctr << 8 | UInt64(b) }
        guard ctr == recvCtr else { throw SpecterCryptoError.counter }
        let body = wire.subdata(in: base + 8 ..< wire.endIndex)
        let ctEnd = body.count - 16
        let ct = body.subdata(in: body.startIndex ..< body.startIndex + ctEnd)
        let tag = body.subdata(in: body.startIndex + ctEnd ..< body.endIndex)
        var nonceData = recvPrefix
        nonceData.append(ctrData)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ct, tag: tag)
        let pt = try AES.GCM.open(box, using: dec)
        recvCtr &+= 1
        return pt
    }
}

// MARK: - Handshake key schedule (client role)

func deriveClientChannel(shared: Data, transcript: Data) -> SecureChannel {
    let keyS2C = hkdfSHA256(ikm: shared, salt: transcript, info: Data("specter/key/s2c".utf8), length: 32)
    let keyC2S = hkdfSHA256(ikm: shared, salt: transcript, info: Data("specter/key/c2s".utf8), length: 32)
    let preS2C = hkdfSHA256(ikm: shared, salt: transcript, info: Data("specter/pre/s2c".utf8), length: 4)
    let preC2S = hkdfSHA256(ikm: shared, salt: transcript, info: Data("specter/pre/c2s".utf8), length: 4)
    // client sends c2s, receives s2c
    return SecureChannel(sendKey: keyC2S, recvKey: keyS2C, sendPrefix: preC2S, recvPrefix: preS2C)
}
