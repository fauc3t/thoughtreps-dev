import CryptoKit
import Foundation

/// A vault id is the unpadded base64url of 16 random bytes.
enum SyncVaultID {
    static let byteCount = 16

    static func bytes(_ vaultID: String) -> Data? {
        guard let data = SyncCrypto.base64URLDecode(vaultID), data.count == byteCount else { return nil }
        return data
    }
}

/// The vault key written out for a person to keep or type on another device. The format is permanent.
///
/// 50 bytes: the vault id's 16 raw bytes | K (32) | the first 2 bytes of SHA-256(vault id bytes | K). That is 400 bits, exactly
/// 80 Crockford base32 characters (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`, most significant bit first), shown as 20 groups of 4
/// joined by `-`. Reading ignores case, spaces, hyphens and line breaks, takes I and L for 1 and O for 0, and checks the
/// length and the checksum before anything else happens.
enum SyncRecoveryCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let characterCount = 80
    static let groupSize = 4

    enum Failure: Error, Equatable {
        case notAVault
        case wrongLength
        case invalidCharacter
        case badChecksum

        var message: String {
            switch self {
            case .notAVault: "This vault can't be written as a recovery code."
            case .wrongLength: "The recovery code should be 80 characters (20 groups of 4). Check that none are missing."
            case .invalidCharacter: "The recovery code has a character that isn't allowed. Codes use only digits and letters (no U)."
            case .badChecksum: "The recovery code doesn't check out. A character is probably mistyped."
            }
        }
    }

    struct Parsed: Equatable {
        var vaultID: String
        var vaultKey: Data
    }

    static func encode(vaultID: String, vaultKey: Data) throws -> String {
        guard let id = SyncVaultID.bytes(vaultID), vaultKey.count == SyncKeys.keyLength else { throw Failure.notAVault }
        let raw = id + vaultKey + checksum(id: id, key: vaultKey)
        var characters: [Character] = []
        var buffer = 0
        var bits = 0
        for byte in raw {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                characters.append(alphabet[buffer >> (bits - 5) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        return stride(from: 0, to: characters.count, by: groupSize)
            .map { String(characters[$0..<min($0 + groupSize, characters.count)]) }
            .joined(separator: "-")
    }

    static func parse(_ text: String) throws -> Parsed {
        var values: [Int] = []
        for scalar in text.unicodeScalars {
            if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            var character = Character(scalar).uppercased()
            if character == "I" || character == "L" { character = "1" }
            if character == "O" { character = "0" }
            guard character.count == 1, let index = alphabet.firstIndex(of: Character(character)) else { throw Failure.invalidCharacter }
            values.append(index)
        }
        guard values.count == characterCount else { throw Failure.wrongLength }
        var raw = Data()
        var buffer = 0
        var bits = 0
        for value in values {
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                raw.append(UInt8(buffer >> (bits - 8) & 255))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        let id = raw.prefix(SyncVaultID.byteCount)
        let key = raw.dropFirst(SyncVaultID.byteCount).prefix(SyncKeys.keyLength)
        guard raw.suffix(2) == checksum(id: Data(id), key: Data(key)) else { throw Failure.badChecksum }
        return Parsed(vaultID: SyncCrypto.base64URL(Data(id)), vaultKey: Data(key))
    }

    private static func checksum(id: Data, key: Data) -> Data {
        Data(SHA256.hash(data: id + key).prefix(2))
    }
}

/// What the QR code of "Add a device" carries: `thoughtreps-pair:v1:<vault id>:<pairing secret>:<K>`, the last two as unpadded
/// base64url. Anything else is refused. No URL scheme is registered for it, so only the in-app scanner reads it. The format
/// is permanent.
struct SyncPairingInvite: Equatable {
    static let prefix = "thoughtreps-pair:v1:"
    static let secretByteRange = 16...64

    var vaultID: String
    var pairingSecret: Data
    var vaultKey: Data

    enum Failure: Error, Equatable {
        case malformed

        var message: String { "That isn't a Thought Reps pairing code." }
    }

    var payload: String {
        Self.prefix + [vaultID, SyncCrypto.base64URL(pairingSecret), SyncCrypto.base64URL(vaultKey)].joined(separator: ":")
    }

    init(vaultID: String, pairingSecret: Data, vaultKey: Data) {
        self.vaultID = vaultID
        self.pairingSecret = pairingSecret
        self.vaultKey = vaultKey
    }

    init(parsing payload: String) throws {
        guard payload.hasPrefix(Self.prefix) else { throw Failure.malformed }
        let fields = payload.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, SyncVaultID.bytes(fields[0]) != nil,
              let secret = SyncCrypto.base64URLDecode(fields[1]), Self.secretByteRange.contains(secret.count),
              let key = SyncCrypto.base64URLDecode(fields[2]), key.count == SyncKeys.keyLength
        else { throw Failure.malformed }
        self.init(vaultID: fields[0], pairingSecret: secret, vaultKey: key)
    }

    /// What `POST /vaults/{id}/invites` takes as `secretHash`.
    var secretHash: String {
        Data(SHA256.hash(data: pairingSecret)).base64EncodedString()
    }
}

/// Whether a device that already has thoughts merges them with the vault's or erases them before joining. Pure, so the
/// order of the two prompts is tested without a view: erasing always passes through a second, destructive confirmation, and
/// cancelling that returns to the first prompt.
enum JoinGate {
    enum Step: Equatable {
        /// Asked first, before anything else: share this device's thoughts with that vault?
        case confirmJoin(thoughtCount: Int)
        case askMergeOrErase(count: Int)
        case confirmErase(count: Int)
        /// Go ahead; `eraseFirst` runs `ThoughtStore.deleteAll` after `/pair` succeeds and before sync starts.
        case join(eraseFirst: Bool)
        case cancelled
    }

    enum Action: Equatable {
        case confirmJoin
        case merge
        case erase
        case confirmErase
        case cancel
    }

    static func begin(thoughtCount: Int) -> Step {
        .confirmJoin(thoughtCount: thoughtCount)
    }

    static func advance(_ step: Step, _ action: Action) -> Step {
        switch (step, action) {
        case (.confirmJoin(let count), .confirmJoin): count > 0 ? .askMergeOrErase(count: count) : .join(eraseFirst: false)
        case (.confirmJoin, .cancel): .cancelled
        case (.askMergeOrErase, .merge): .join(eraseFirst: false)
        case (.askMergeOrErase(let count), .erase): .confirmErase(count: count)
        case (.askMergeOrErase, .cancel): .cancelled
        case (.confirmErase(let count), .cancel): .askMergeOrErase(count: count)
        case (.confirmErase, .confirmErase): .join(eraseFirst: true)
        default: step
        }
    }

    static let joinTitle = "Join this sync vault?"
    static let joinMessage = "Your thoughts on this device will be shared with the devices in it. Only continue with a code from your own device."

    static func count(_ count: Int) -> String {
        "\(count) \(count == 1 ? "thought" : "thoughts")"
    }

    static func askTitle(count: Int, device: String) -> String {
        "This \(device) has \(Self.count(count))"
    }

    static func askMessage(device: String) -> String {
        "Merge them with your synced thoughts, or erase this \(device) first?"
    }

    static func confirmTitle(count: Int, device: String) -> String {
        "Erase \(Self.count(count)) from this \(device)?"
    }

    static let confirmMessage = "This can't be undone. Your synced thoughts aren't affected."
}
