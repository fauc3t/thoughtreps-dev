import CryptoKit
import Foundation
import os
import Security

/// What a device needs to rejoin its vault: the vault key K and the ids. Kept together in one Keychain item.
struct SyncCredentials: Codable, Equatable, Sendable {
    var vaultKey: Data
    var vaultID: String
    var userID: String
}

protocol SyncCredentialStore: Sendable {
    /// Nil only when nothing is stored; any other failure throws.
    func load() throws -> SyncCredentials?
    func save(_ credentials: SyncCredentials) throws
    func clear()
}

/// A single generic-password item. The default never leaves this device: not synchronizable (so not in iCloud Keychain) and
/// only readable after the first unlock, and not restored onto another device from a backup. The `synchronizable` one is the
/// optional iCloud Keychain copy, a separate item (`ICloudKeyCopy`) that the engine never reads.
struct KeychainSyncCredentialStore: SyncCredentialStore {
    static let iCloudService = "com.thoughtreps.sync.credentials.icloud"

    private static let log = Logger(subsystem: "com.thoughtreps", category: "KeychainSyncCredentialStore")
    private let service: String
    private let synchronizable: Bool
    private let account = "credentials"

    init(service: String = "com.thoughtreps.sync.credentials", synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    static func iCloudCopy() -> KeychainSyncCredentialStore {
        KeychainSyncCredentialStore(service: iCloudService, synchronizable: true)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: synchronizable]
    }

    func load() throws -> SyncCredentials? {
        var item: CFTypeRef?
        let lookup = query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            Self.log.error("Keychain read failed: \(status)")
            throw KeychainStatusError(status: status)
        }
        return try JSONDecoder().decode(SyncCredentials.self, from: data)
    }

    func save(_ credentials: SyncCredentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain write failed: \(status)")
            throw KeychainStatusError(status: status)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The optional copy of the vault key in iCloud Keychain, so a new device of the same Apple account can join. The local item
/// stays what the engine reads; this one is only written when the person leaves the setting on (the default), and deleted
/// when they turn it off.
struct ICloudKeyCopy: @unchecked Sendable {
    static let defaultsKey = "syncSaveKeyToICloudKeychain"

    var store: SyncCredentialStore
    var defaults: UserDefaults

    init(store: SyncCredentialStore = KeychainSyncCredentialStore.iCloudCopy(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    /// Turning it on writes `local` if there is a key; turning it off deletes the copy.
    func setEnabled(_ enabled: Bool, local: SyncCredentials?) throws {
        defaults.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            if let local { try store.save(local) }
        } else {
            store.clear()
        }
    }

    /// Writes the copy if the setting is on. A failure is the caller's to log: the vault works without the copy.
    func saveIfEnabled(_ credentials: SyncCredentials) throws {
        guard isEnabled else { return }
        try store.save(credentials)
    }

    func load() throws -> SyncCredentials? {
        try store.load()
    }

    func delete() {
        store.clear()
    }
}

extension SyncKeys {
    /// What `POST /vaults` takes as `kAuthVerifier`: the standard base64 of the SHA-256 of K_auth's 32 raw bytes. The server
    /// checks the same hash against the K_auth a joining device proves it holds.
    var authVerifier: String {
        Data(SHA256.hash(data: authBytes)).base64EncodedString()
    }

    /// K_auth's 32 raw bytes: what a joining device sends to `/pair` as `kAuth`.
    var authBytes: Data {
        auth.withUnsafeBytes { Data($0) }
    }
}

/// Failures of the sync account calls. A refusal keeps the server's `error` code.
enum SyncAccountError: Error, Equatable {
    /// The server's `error` codes for the account routes.
    enum Code: String {
        case vaultExists = "vault_exists"
        case assertionInvalid = "assertion_invalid"
        case challengeInvalid = "challenge_invalid"
        case attestationInvalid = "attestation_invalid"
        case identityTokenInvalid = "identity_token_invalid"
        case forbidden
        case deviceInVault = "device_in_vault"
        case unauthorized
        case pairingFailed = "pairing_failed"
        case deviceLimit = "device_limit"
        case tooManyInvites = "too_many_invites"
    }

    case unsupported
    case attestationFailed
    /// App Attest no longer has the stored key (`DCError.invalidKey`).
    case staleKey
    case keychainFailed
    case appleSignInCancelled
    case appleSignInFailed
    /// A session was asked for before this device registered its App Attest key.
    case notRegistered
    case offline
    case network
    case invalidResponse
    case server(status: Int, code: String?)

    var code: Code? {
        if case .server(_, let raw?) = self { return Code(rawValue: raw) }
        return nil
    }

    /// The device key is unusable: gone from App Attest, or unknown to the server.
    var isStaleKey: Bool {
        if self == .staleKey { return true }
        if case .server(401, _) = self, code == .assertionInvalid { return true }
        return false
    }

    /// What the Sync lab says about a failed join or invite.
    var pairingMessage: String {
        switch code {
        case .pairingFailed: "Couldn't join: the code was wrong, expired or already used."
        case .deviceLimit: "This vault already has the most devices. Remove one first."
        case .deviceInVault: "This device already belongs to a vault. Forget its key or remove it from that vault first."
        case .tooManyInvites: "Too many open invitations. Wait a few minutes for them to expire."
        default:
            switch self {
            case .offline: "You're offline."
            case .unsupported: "App Attest isn't available on this device."
            default: "Failed: \(self)"
            }
        }
    }

    static func from(status: Int, body: Data) -> SyncAccountError {
        let raw = (try? JSONDecoder().decode(SyncHTTPWireV1.ErrorBody.self, from: body))?.error
        return .server(status: status, code: raw)
    }

    /// A refusal the request can't recover from (400, 401, 403, 404, 410) stops the engine; anything else is a failed call.
    var transportError: SyncTransportError {
        guard case .server(let status, let code) = self, [400, 401, 403, 404, 410].contains(status) else { return .unavailable }
        return .refused(status: status, message: code ?? "")
    }
}

/// How `HTTPSyncTransport` proves who it is.
enum SyncAuth: Sendable {
    /// `Authorization: Dev <secret>` and `x-tr-vault`: the dev server and the local test server.
    case devSecret(String)
    /// `Authorization: Bearer <token>` and nothing else: the server takes the vault from the token.
    case session(any SyncSessionSource)
}

/// Hands out bearer tokens, minting a new one when the current is near expiry. Implementations share one refresh among
/// concurrent callers.
protocol SyncSessionSource: Sendable {
    func token() async throws -> String
    /// A token other than `rejected`, which the server answered 401.
    func refresh(after rejected: String) async throws -> String
}
