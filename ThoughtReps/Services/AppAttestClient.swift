import CryptoKit
import DeviceCheck
import Foundation
import os
import Security

/// Typed failures from the Thought Reps API. The server cases mirror its `{error, message}` codes.
enum APIError: Error, Equatable {
    case unsupported
    case badRequest
    case attestationInvalid
    case assertionInvalid
    case challengeInvalid
    case rateLimited
    case tooLarge
    case notFound
    case uploadMismatch
    case used
    case expired
    case revoked
    case offline
    case network
    case attestationFailed
    case keychainFailed
    case server(status: Int)
    case invalidResponse

    /// A 500 carries `{message}` with no `error` field, so any other shape falls through to `.server`.
    static func from(status: Int, body: Data) -> APIError {
        if status == 429 { return .rateLimited }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        switch code {
        case "bad_request": return .badRequest
        case "attestation_invalid": return .attestationInvalid
        case "assertion_invalid": return .assertionInvalid
        case "challenge_invalid": return .challengeInvalid
        case "rate_limited": return .rateLimited
        case "too_large": return .tooLarge
        case "not_found": return .notFound
        case "upload_mismatch": return .uploadMismatch
        case "used": return .used
        case "expired": return .expired
        case "revoked": return .revoked
        default: return .server(status: status)
        }
    }

    private struct ErrorBody: Decodable { let error: String? }
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
}

/// The App Attest calls the client makes, so tests can substitute a fake.
protocol AttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

struct DeviceCheckAttestService: AttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// Where the registered App Attest keyId lives between launches.
protocol KeyIdStore: Sendable {
    /// Nil only when no key is stored; any other failure throws.
    func load() throws -> String?
    func save(_ keyId: String) throws
    func clear()
}

struct KeychainStatusError: Error, Equatable { let status: OSStatus }

struct KeychainKeyIdStore: KeyIdStore {
    private static let log = Logger(subsystem: "com.thoughtreps", category: "KeychainKeyIdStore")
    private let service = "com.thoughtreps.appattest"
    private let account = "keyId"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    func save(_ keyId: String) throws {
        clear()
        let attributes = query.merging([
            kSecValueData as String: Data(keyId.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("Keychain write failed: \(status)")
            throw KeychainStatusError(status: status)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Signs requests to the Thought Reps API with App Attest. Build each endpoint on `signedPost`.
///
/// The first signed call registers the device (generate key, attest a server challenge, `POST /devices`)
/// and stores the keyId in the Keychain only after the server accepted it. Registration is serialized
/// so concurrent calls attest once. If the server rejects the key as unknown, the key is discarded and
/// the device registers again, once.
actor AppAttestClient {
    static let productionBaseURL = URL(string: "https://transfer.thoughtreps.com/api/v1")!
    static let shared = AppAttestClient()

    private let baseURL: URL
    private let transport: HTTPTransport
    private let attest: AttestService
    private let keyStore: KeyIdStore
    private var registration: Task<String, Error>?

    init(
        baseURL: URL = AppAttestClient.productionBaseURL,
        transport: HTTPTransport = URLSessionTransport(),
        attest: AttestService = DeviceCheckAttestService(),
        keyStore: KeyIdStore = KeychainKeyIdStore()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.attest = attest
        self.keyStore = keyStore
    }

    /// Sends a signed JSON POST. `makeBody` receives a fresh single-use challenge to embed in the body.
    func signedPost<Body: Encodable, Response: Decodable>(
        _ path: String,
        body makeBody: @Sendable (_ challenge: String) -> Body,
        response: Response.Type
    ) async throws -> Response {
        guard attest.isSupported else { throw APIError.unsupported }
        var canReregister = true
        while true {
            let keyId = try await registeredKeyId()
            do {
                let challenge = try await fetchChallenge()
                let bodyData = try JSONEncoder().encode(makeBody(challenge))
                let assertion = try await assertion(keyId: keyId, body: bodyData)
                let request = Self.signedRequest(url: url(path), body: bodyData, keyId: keyId, assertion: assertion)
                return try decode(try await perform(request), as: response)
            } catch APIError.assertionInvalid where canReregister {
                canReregister = false
                if (try? keyStore.load()) == keyId { keyStore.clear() }
            }
        }
    }

    /// Attestation signs the challenge string's UTF-8 bytes, not the decoded challenge.
    static func attestationClientDataHash(challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }

    /// Assertions sign the request body bytes exactly as sent.
    static func assertionClientDataHash(body: Data) -> Data {
        Data(SHA256.hash(data: body))
    }

    static func signedRequest(url: URL, body: Data, keyId: String, assertion: Data) -> URLRequest {
        var request = jsonRequest(url: url, body: body)
        request.setValue(keyId, forHTTPHeaderField: "x-tr-key-id")
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "x-tr-assertion")
        return request
    }

    private static func jsonRequest(url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func assertion(keyId: String, body: Data) async throws -> Data {
        do {
            return try await attest.generateAssertion(keyId, clientDataHash: Self.assertionClientDataHash(body: body))
        } catch let error as DCError where error.code == .invalidKey {
            throw APIError.assertionInvalid
        } catch {
            throw APIError.attestationFailed
        }
    }

    private func registeredKeyId() async throws -> String {
        do {
            if let stored = try keyStore.load() { return stored }
        } catch {
            throw APIError.keychainFailed
        }
        if let registration { return try await registration.value }
        let task = Task { try await register() }
        registration = task
        defer { registration = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        let challenge = try await fetchChallenge()
        let keyId: String
        let attestation: Data
        do {
            keyId = try await attest.generateKey()
            attestation = try await attest.attestKey(keyId, clientDataHash: Self.attestationClientDataHash(challenge: challenge))
        } catch {
            throw APIError.attestationFailed
        }
        let body = try JSONEncoder().encode(
            RegisterBody(keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge)
        )
        _ = try await perform(Self.jsonRequest(url: url("devices"), body: body))
        do { try keyStore.save(keyId) } catch { throw APIError.keychainFailed }
        return keyId
    }

    private func fetchChallenge() async throws -> String {
        let data = try await perform(Self.jsonRequest(url: url("challenge"), body: Data("{}".utf8)))
        return try decode(data, as: ChallengeBody.self).challenge
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw error.code == .cancelled ? CancellationError() : Self.map(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw APIError.invalidResponse }
    }

    static func map(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .dataNotAllowed,
             .cannotConnectToHost, .cannotFindHost, .internationalRoamingOff:
            return .offline
        default:
            return .network
        }
    }

    private struct ChallengeBody: Decodable { let challenge: String }

    private struct RegisterBody: Encodable {
        let keyId: String
        let attestation: String
        let challenge: String
    }
}
