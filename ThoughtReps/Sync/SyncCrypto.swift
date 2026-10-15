import CryptoKit
import Foundation

/// The four keys derived from the 32-byte vault key K (HKDF-SHA256). The `info` strings are versioned
/// so a key can be re-derived differently later without touching the others. All four are permanent;
/// `auth`'s becomes part of the server protocol once phase 2 derives the verifier from it.
struct SyncKeys: Sendable {
    let record: SymmetricKey
    let blob: SymmetricKey
    let index: SymmetricKey
    let auth: SymmetricKey

    static let keyLength = 32

    enum Failure: Error, Equatable {
        case badKeyLength
    }

    init(vaultKey: Data) throws {
        guard vaultKey.count == Self.keyLength else { throw Failure.badKeyLength }
        let root = SymmetricKey(data: vaultKey)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data(info.utf8), outputByteCount: Self.keyLength)
        }
        record = derive("thoughtreps.sync.v1.record")
        blob = derive("thoughtreps.sync.v1.blob")
        index = derive("thoughtreps.sync.v1.index")
        auth = derive("thoughtreps.sync.v1.auth")
    }

    /// The opaque, deterministic key the server stores a record under: HMAC-SHA256 of the type and entity
    /// id, base64url without padding.
    func recordKey(type: SyncRecordType, entityID: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(type.rawValue)|\(entityID)".utf8), using: index)
        return SyncCrypto.base64URL(Data(mac))
    }

    /// The name an image or file is stored under on the server: an HMAC of its id, so the server never sees ids.
    /// Assets are immutable, so the name never has to change.
    func blobName(kind: SyncBlobKind, id: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("blob.\(kind.rawValue)|\(id.uuidString)".utf8), using: index)
        return SyncCrypto.base64URL(Data(mac))
    }
}

extension SyncKeys {
    /// Where a sealed record too big to go inline is stored: an HMAC of the record key and the plaintext hash, so a new
    /// version gets a new name and a retried push finds its blob already there. Both inputs are base64url or hex, so
    /// they can't contain the `|` that separates them.
    func recordBlobName(recordKey: String, hash: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("blob.record|\(recordKey)|\(hash)".utf8), using: index)
        return SyncCrypto.base64URL(Data(mac))
    }
}

enum SyncBlobKind: String, Sendable {
    case image
    case file
}

/// Seals and opens record payloads, blobs and pointers. Layouts (all integers big-endian):
///
/// - Record frame: `"TRS1"` | key generation (1 byte, 1) | payload version (1 byte) | nonce (12) | ciphertext | tag (16).
///   The ciphertext is `u32 plaintext length | plaintext | zero padding`, padded so the whole frame lands on a size bucket
///   (`bucket(forFrameBytes:)`). AAD: `lp(vaultId) | lp(recordKey) | u32 payload version | u8 key generation`, where `lp` is
///   a `u32` byte count followed by the UTF-8 bytes. Sealed with `K_rec`.
/// - Blob frame: `"TRSB"` | key generation (1) | nonce (12) | ciphertext (the data, not padded) | tag (16). AAD:
///   `lp(vaultId) | lp(name) | u8 key generation`. Sealed with `K_blob`; it holds images, files and sealed records over the
///   inline limit.
/// - Pointer, the payload of a record whose sealed frame went to a blob: `"TRP1"` | the 43-character blob name.
///
/// A frame with a `TR*` magic this build doesn't know, or a key generation past `currentKeyGeneration`, is from a newer
/// app: `Failure.unrecognizedMagic` and `unsupportedKeyGeneration`, which callers park instead of treating as damage.
enum SyncCrypto {
    static let magic = Data("TRS1".utf8)
    static let blobMagic = Data("TRSB".utf8)
    static let pointerMagic = Data("TRP1".utf8)
    static let currentKeyGeneration: UInt8 = 1
    /// Bumped with any change that lets this build read what an older one parked (see `SyncEngine.Configuration.readerVersion`).
    static let readerVersion = 1

    /// Magic, key generation, payload version, nonce and tag: everything in a record frame but the padded plaintext.
    static let overheadBytes = 4 + 1 + 1 + 12 + 16
    /// Magic, key generation, nonce and tag.
    static let blobOverheadBytes = 4 + 1 + 12 + 16
    static let lengthPrefixBytes = 4
    /// A blob name is an HMAC-SHA256 in base64url without padding.
    static let blobNameLength = 43

    private static let smallestBucket = 512
    private static let largeStep = 1 << 20

    enum Failure: Error, Equatable {
        case badFormat
        case decryptionFailed
        case invalidVersion
        /// A `TR*` magic this build doesn't know: a frame from a newer version of the app.
        case unrecognizedMagic
        case unsupportedKeyGeneration(Int)
    }

    struct Opened: Equatable, Sendable {
        var payloadVersion: Int
        var plaintext: Data
    }

    /// The size a sealed record of `bytes` is padded up to: a power of two from 512 B to 1 MiB, then whole MiB, so the
    /// server sees only the bucket and not the length.
    static func bucket(forFrameBytes bytes: Int) -> Int {
        if bytes > largeStep { return (bytes + largeStep - 1) / largeStep * largeStep }
        var size = smallestBucket
        while size < bytes { size <<= 1 }
        return size
    }

    /// `nonce` and `keyGeneration` are seams for tests; the defaults are a fresh random nonce and the current generation.
    static func seal(
        _ plaintext: Data, vaultID: String, recordKey: String, payloadVersion: Int, keys: SyncKeys, nonce: AES.GCM.Nonce? = nil,
        keyGeneration: UInt8 = currentKeyGeneration
    ) throws -> Data {
        guard let version = UInt8(exactly: payloadVersion) else { throw Failure.invalidVersion }
        let paddedBytes = bucket(forFrameBytes: overheadBytes + lengthPrefixBytes + plaintext.count) - overheadBytes
        var padded = Data(capacity: paddedBytes)
        padded.append(bigEndian: UInt32(plaintext.count))
        padded.append(plaintext)
        padded.append(Data(count: paddedBytes - padded.count))
        let box = try AES.GCM.seal(
            padded, using: keys.record, nonce: nonce,
            authenticating: recordAAD(vaultID: vaultID, recordKey: recordKey, payloadVersion: payloadVersion, keyGeneration: keyGeneration)
        )
        var frame = Data(capacity: paddedBytes + overheadBytes)
        frame.append(magic)
        frame.append(keyGeneration)
        frame.append(version)
        frame.append(contentsOf: box.nonce)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    /// `badFormat` is a wrong prefix or a truncated frame; `decryptionFailed` is a wrong key, a ciphertext
    /// moved to another record or vault, or a frame changed after sealing.
    static func open(
        _ frame: Data, vaultID: String, recordKey: String, keys: SyncKeys, readableKeyGeneration: UInt8 = currentKeyGeneration
    ) throws -> Opened {
        let frame = Data(frame)
        try checkMagic(frame, expected: magic)
        guard frame.count >= overheadBytes + lengthPrefixBytes else { throw Failure.badFormat }
        try checkKeyGeneration(frame[4], readable: readableKeyGeneration)
        let version = Int(frame[5])
        let padded: Data
        do {
            let box = try AES.GCM.SealedBox(combined: frame.dropFirst(6))
            padded = try AES.GCM.open(
                box, using: keys.record, authenticating: recordAAD(vaultID: vaultID, recordKey: recordKey, payloadVersion: version, keyGeneration: frame[4])
            )
        } catch {
            throw Failure.decryptionFailed
        }
        guard padded.count >= lengthPrefixBytes else { throw Failure.badFormat }
        let length = padded.prefix(lengthPrefixBytes).reduce(0) { $0 << 8 | Int($1) }
        guard length <= padded.count - lengthPrefixBytes else { throw Failure.badFormat }
        return Opened(payloadVersion: version, plaintext: Data(padded.dropFirst(lengthPrefixBytes).prefix(length)))
    }

    static func sealBlob(_ data: Data, vaultID: String, name: String, keys: SyncKeys, nonce: AES.GCM.Nonce? = nil) throws -> Data {
        let box = try AES.GCM.seal(data, using: keys.blob, nonce: nonce, authenticating: blobAAD(vaultID: vaultID, name: name))
        var frame = Data(capacity: data.count + blobOverheadBytes)
        frame.append(blobMagic)
        frame.append(currentKeyGeneration)
        frame.append(contentsOf: box.nonce)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    static func openBlob(_ frame: Data, vaultID: String, name: String, keys: SyncKeys) throws -> Data {
        let frame = Data(frame)
        try checkMagic(frame, expected: blobMagic)
        guard frame.count >= blobOverheadBytes else { throw Failure.badFormat }
        try checkKeyGeneration(frame[4], readable: currentKeyGeneration)
        do {
            let box = try AES.GCM.SealedBox(combined: frame.dropFirst(5))
            return try AES.GCM.open(box, using: keys.blob, authenticating: blobAAD(vaultID: vaultID, name: name))
        } catch {
            throw Failure.decryptionFailed
        }
    }

    static func pointer(toBlob name: String) -> Data {
        pointerMagic + Data(name.utf8)
    }

    /// The blob a pointer names; nil unless `payload` is `TRP1` and exactly one well-formed blob name.
    static func blobName(inPointer payload: Data) -> String? {
        guard payload.count == pointerMagic.count + blobNameLength, payload.prefix(pointerMagic.count) == pointerMagic else { return nil }
        let name = payload.dropFirst(pointerMagic.count)
        guard name.allSatisfy({ isBase64URL($0) }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `vaultId | recordKey | payloadVersion | keyGeneration`, each string preceded by its byte length so no choice of
    /// field contents can produce the same bytes as another.
    static func recordAAD(vaultID: String, recordKey: String, payloadVersion: Int, keyGeneration: UInt8 = currentKeyGeneration) -> Data {
        var data = lengthPrefixed(vaultID, recordKey)
        data.append(bigEndian: UInt32(payloadVersion))
        data.append(keyGeneration)
        return data
    }

    /// `vaultId | name | keyGeneration`, built like `recordAAD`.
    static func blobAAD(vaultID: String, name: String) -> Data {
        var data = lengthPrefixed(vaultID, name)
        data.append(currentKeyGeneration)
        return data
    }

    private static func lengthPrefixed(_ fields: String...) -> Data {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(bigEndian: UInt32(bytes.count))
            data.append(bytes)
        }
        return data
    }

    /// A known magic in the wrong place, or anything not starting `TR`, is damage; any other `TR*` is a newer format.
    private static func checkMagic(_ frame: Data, expected: Data) throws {
        let prefix = frame.prefix(4)
        if prefix == expected { return }
        let known = [magic, blobMagic, pointerMagic]
        guard prefix.count == 4, prefix.starts(with: Data("TR".utf8)), !known.contains(prefix) else { throw Failure.badFormat }
        throw Failure.unrecognizedMagic
    }

    private static func checkKeyGeneration(_ generation: UInt8, readable: UInt8) throws {
        guard generation != 0 else { throw Failure.badFormat }
        guard generation <= readable else { throw Failure.unsupportedKeyGeneration(Int(generation)) }
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
