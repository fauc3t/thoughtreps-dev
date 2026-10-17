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

/// A single generic-password item that never leaves this device: not synchronizable (so not in iCloud Keychain) and only
/// readable after the first unlock, and not restored onto another device from a backup.
struct KeychainSyncCredentialStore: SyncCredentialStore {
    private static let log = Logger(subsystem: "com.thoughtreps", category: "KeychainSyncCredentialStore")
    private let service: String
    private let account = "credentials"

    init(service: String = "com.thoughtreps.sync.credentials") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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

extension SyncKeys {
    /// What `POST /vaults` takes as `kAuthVerifier`: the standard base64 of the SHA-256 of K_auth's 32 raw bytes. The server
    /// checks the same hash against the K_auth a joining device proves it holds.
    var authVerifier: String {
        let raw = auth.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: raw)).base64EncodedString()
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
