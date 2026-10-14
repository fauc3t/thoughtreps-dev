import CryptoKit
import Foundation

/// The four keys derived from the 32-byte vault key K (HKDF-SHA256). The `info` strings are versioned
/// so a key can be re-derived differently later without touching the others.
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
}

/// Seals and opens record payloads. The frame is `"TRS1"` + one byte of payload version + a 12-byte
/// nonce + ciphertext + a 16-byte AES-256-GCM tag. The AAD is `vaultId | recordKey | payloadVersion`,
/// so the server can't move a ciphertext to another record, another vault or another version.
enum SyncCrypto {
    static let magic = Data("TRS1".utf8)
    static let overheadBytes = 4 + 1 + 12 + 16

    enum Failure: Error, Equatable {
        case badFormat
        case decryptionFailed
        case invalidVersion
    }

    struct Opened: Equatable, Sendable {
        var payloadVersion: Int
        var plaintext: Data
    }

    static func seal(_ plaintext: Data, vaultID: String, recordKey: String, payloadVersion: Int, keys: SyncKeys) throws -> Data {
        guard let version = UInt8(exactly: payloadVersion) else { throw Failure.invalidVersion }
        let box = try AES.GCM.seal(
            plaintext, using: keys.record, authenticating: aad(vaultID: vaultID, recordKey: recordKey, payloadVersion: payloadVersion)
        )
        var frame = Data(capacity: plaintext.count + overheadBytes)
        frame.append(magic)
        frame.append(version)
        frame.append(contentsOf: box.nonce)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    /// `badFormat` is a wrong prefix or a truncated frame; `decryptionFailed` is a wrong key, a ciphertext
    /// moved to another record or vault, or a frame changed after sealing.
    static func open(_ frame: Data, vaultID: String, recordKey: String, keys: SyncKeys) throws -> Opened {
        guard frame.count >= overheadBytes, frame.prefix(magic.count) == magic else { throw Failure.badFormat }
        let body = frame.dropFirst(magic.count)
        let version = Int(body[body.startIndex])
        do {
            let box = try AES.GCM.SealedBox(combined: body.dropFirst())
            let plaintext = try AES.GCM.open(
                box, using: keys.record, authenticating: aad(vaultID: vaultID, recordKey: recordKey, payloadVersion: version)
            )
            return Opened(payloadVersion: version, plaintext: plaintext)
        } catch {
            throw Failure.decryptionFailed
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `vaultId | recordKey | payloadVersion`, each string preceded by its byte length so no choice of
    /// field contents can produce the same bytes as another.
    static func aad(vaultID: String, recordKey: String, payloadVersion: Int) -> Data {
        var data = Data()
        for field in [vaultID, recordKey] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        withUnsafeBytes(of: UInt32(payloadVersion).bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}
