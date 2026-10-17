#if DEBUG
import AuthenticationServices
import CryptoKit
import DeviceCheck
import Foundation
import UIKit

/// DEBUG only: the sync server's account calls. Sync has its own App Attest key (a separate Keychain item from the export
/// link and feedback key), because the sync server keeps its own device table.
struct SyncAccountAPI: Sendable {
    /// The dev deployment (phase 4a). `THOUGHTREPS_SYNC_URL` overrides it.
    static let devBaseURL = URL(string: "https://glbchxtwj9.execute-api.us-east-1.amazonaws.com/api/v1")!

    static func defaultBaseURL(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let url = environment["THOUGHTREPS_SYNC_URL"].flatMap(URL.init(string:)), url.scheme != nil { return url }
        return devBaseURL
    }

    static func defaultKeyStore() -> KeyIdStore {
        KeychainKeyIdStore(service: "com.thoughtreps.sync.appattest")
    }

    var baseURL: URL
    var transport: HTTPTransport = URLSessionTransport()
    var attest: AttestService = DeviceCheckAttestService()
    var keyStore: KeyIdStore = SyncAccountAPI.defaultKeyStore()

    static func encode(_ body: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    func challenge() async throws -> String {
        let answer: SyncHTTPWireV1.DeviceChallenge = try await post("devices/app-attest/challenge", body: Data("{}".utf8))
        return answer.challenge
    }

    /// The stored key, or a newly generated one registered with the server (and stored only after it accepted it).
    func registeredKeyId() async throws -> String {
        if let stored = try storedKeyId() { return stored }
        let challenge = try await challenge()
        let keyId: String
        let attestation: Data
        do {
            keyId = try await attest.generateKey()
            attestation = try await attest.attestKey(keyId, clientDataHash: AppAttestClient.attestationClientDataHash(challenge: challenge))
        } catch {
            throw SyncAccountError.attestationFailed
        }
        let body = try Self.encode(SyncHTTPWireV1.DeviceRegisterRequest(keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge))
        let _: SyncHTTPWireV1.DeviceRegisterResponse = try await post("devices/app-attest/register", body: body)
        do { try keyStore.save(keyId) } catch { throw SyncAccountError.keychainFailed }
        return keyId
    }

    func storedKeyId() throws -> String? {
        do { return try keyStore.load() } catch { throw SyncAccountError.keychainFailed }
    }

    /// A POST signed with the device key. If the key is unusable (gone from App Attest, or the server says
    /// `assertion_invalid`), the stored keyId is dropped, a new key is registered and the call is repeated once; a second
    /// failure surfaces. The new key is a new device on the server: the old device record stays in the vault (and counts
    /// toward the device limit) until device removal exists, and the new key is no vault member until pairing exists.
    func signedPost<Response: Decodable>(_ path: String, keyId: String, body: some Encodable) async throws -> Response {
        do {
            return try await signedPostOnce(path, keyId: keyId, body: body)
        } catch let error as SyncAccountError where error.isStaleKey {
            keyStore.clear()
            return try await signedPostOnce(path, keyId: try await registeredKeyId(), body: body)
        }
    }

    private func signedPostOnce<Response: Decodable>(_ path: String, keyId: String, body: some Encodable) async throws -> Response {
        let bytes = try Self.encode(body)
        let assertion: Data
        do {
            assertion = try await attest.generateAssertion(keyId, clientDataHash: AppAttestClient.assertionClientDataHash(body: bytes))
        } catch let error as DCError where error.code == .invalidKey {
            throw SyncAccountError.staleKey
        } catch {
            throw SyncAccountError.attestationFailed
        }
        let request = AppAttestClient.signedRequest(url: baseURL.appending(path: path), body: bytes, keyId: keyId, assertion: assertion)
        return try decode(try await perform(request))
    }

    func post<Response: Decodable>(_ path: String, body: Data, bearer: String? = nil) async throws -> Response {
        var request = AppAttestClient.jsonRequest(url: baseURL.appending(path: path), body: body)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try decode(try await perform(request))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AppAttestClient.map(error) == .offline ? SyncAccountError.offline : SyncAccountError.network
        }
        guard (200..<300).contains(response.statusCode) else { throw SyncAccountError.from(status: response.statusCode, body: data) }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SyncAccountError.invalidResponse }
    }
}

/// Runs Sign in with Apple and returns the identity token. Behind a protocol so tests can fake it.
protocol AppleSignIn: Sendable {
    /// `nonce` goes into the request as is; Apple puts it in the token.
    func identityToken(nonce: String) async throws -> String
}

struct SyncAccountService: Sendable {
    enum Outcome: Equatable {
        /// A new vault, whose key is now in the credential store.
        case vaultCreated(SyncCredentials, SyncHTTPWireV1.SessionToken)
        /// The account's vault is the one this device already holds the key for.
        case signedIn(SyncCredentials, SyncHTTPWireV1.SessionToken)
        /// The account has a vault but this device has no key for it; joining comes with pairing.
        case accountHasVault
        /// This device is registered to a vault of another account.
        case deviceInVault
    }

    var api: SyncAccountAPI
    var apple: AppleSignIn
    var credentials: SyncCredentialStore
    var makeVaultKey: @Sendable () -> Data = { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// What Apple must put in the identity token for `challenge`: its lowercase hex SHA-256.
    static func nonce(for challenge: String) -> String {
        SHA256.hash(data: Data(challenge.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signInAndCreateVault() async throws -> Outcome {
        guard api.attest.isSupported else { throw SyncAccountError.unsupported }
        let keyId = try await api.registeredKeyId()
        let account: SyncHTTPWireV1.AccountSession
        do {
            account = try await signIn(keyId: keyId)
        } catch let error as SyncAccountError where error.code == .deviceInVault {
            return .deviceInVault
        }
        if let vaultID = account.vaultId {
            guard let held = try stored(), held.vaultID == vaultID, held.userID == account.userId else { return .accountHasVault }
            return .signedIn(held, account.session)
        }
        return try await createVault(account)
    }

    /// An identity token Apple issued for a stale or already used challenge is rejected; one more try with new ones.
    private func signIn(keyId: String) async throws -> SyncHTTPWireV1.AccountSession {
        var retried = false
        while true {
            let challenge = try await api.challenge()
            let token = try await apple.identityToken(nonce: Self.nonce(for: challenge))
            do {
                return try await api.signedPost(
                    "accounts/sign-in-with-apple", keyId: keyId, body: SyncHTTPWireV1.SignInWithAppleRequest(challenge: challenge, identityToken: token)
                )
            } catch let error as SyncAccountError where error.code == .identityTokenInvalid && !retried {
                retried = true
            }
        }
    }

    private func createVault(_ account: SyncHTTPWireV1.AccountSession) async throws -> Outcome {
        let key = makeVaultKey()
        let verifier = try SyncKeys(vaultKey: key).authVerifier
        let created: SyncHTTPWireV1.CreateAccountVaultResponse
        do {
            created = try await api.post(
                "vaults", body: try SyncAccountAPI.encode(SyncHTTPWireV1.CreateAccountVaultRequest(kAuthVerifier: verifier)), bearer: account.session.token
            )
        } catch let error as SyncAccountError where error.code == .vaultExists {
            return .accountHasVault
        }
        let held = SyncCredentials(vaultKey: key, vaultID: created.vaultId, userID: account.userId)
        do { try credentials.save(held) } catch { throw SyncAccountError.keychainFailed }
        return .vaultCreated(held, created.session)
    }

    private func stored() throws -> SyncCredentials? {
        do { return try credentials.load() } catch { throw SyncAccountError.keychainFailed }
    }
}

/// Keeps a vault session in memory only (never persisted or logged) and mints a new one through the device key when it
/// is missing or within `refreshMargin` of expiring, by the server's clock. Concurrent callers share one mint.
actor SyncSessionProvider: SyncSessionSource {
    static let refreshMargin: TimeInterval = 300

    private let api: SyncAccountAPI
    private let vaultID: String
    private let serverNow: @Sendable () -> Date
    private var current: SyncHTTPWireV1.SessionToken?
    private var minting: Task<SyncHTTPWireV1.SessionToken, Error>?

    init(api: SyncAccountAPI, vaultID: String, serverNow: @escaping @Sendable () -> Date) {
        self.api = api
        self.vaultID = vaultID
        self.serverNow = serverNow
    }

    func adopt(_ session: SyncHTTPWireV1.SessionToken) {
        current = session
    }

    func token() async throws -> String {
        if let current, isFresh(current) { return current.token }
        return try await mint().token
    }

    func refresh(after rejected: String) async throws -> String {
        if let current, current.token != rejected, isFresh(current) { return current.token }
        return try await mint().token
    }

    private func isFresh(_ session: SyncHTTPWireV1.SessionToken) -> Bool {
        Date(timeIntervalSince1970: Double(session.expiresAt) / 1000).timeIntervalSince(serverNow()) > Self.refreshMargin
    }

    private func mint() async throws -> SyncHTTPWireV1.SessionToken {
        if let minting { return try await minting.value }
        let task = Task { try await requestSession() }
        minting = task
        defer { minting = nil }
        let session = try await task.value
        current = session
        return session
    }

    private func requestSession() async throws -> SyncHTTPWireV1.SessionToken {
        guard let keyId = try api.storedKeyId() else { throw SyncAccountError.notRegistered }
        let challenge = try await api.challenge()
        let answer: SyncHTTPWireV1.AccountSession = try await api.signedPost(
            "sessions/app-attest", keyId: keyId, body: SyncHTTPWireV1.SessionRequest(challenge: challenge)
        )
        guard answer.vaultId == vaultID else { throw SyncAccountError.server(status: 403, code: SyncAccountError.Code.forbidden.rawValue) }
        return answer.session
    }
}

/// Sign in with Apple through `ASAuthorizationController`. Needs a device; the simulator can't complete it.
struct AuthenticationServicesSignIn: AppleSignIn {
    func identityToken(nonce: String) async throws -> String {
        try await Self.run(nonce: nonce)
    }

    @MainActor
    private static func run(nonce: String) async throws -> String {
        try await AppleSignInSession().run(nonce: nonce)
    }
}

@MainActor
private final class AppleSignInSession: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?

    func run(nonce: String) async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { ASPresentationAnchor(windowScene: $0) } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
        else { return finish(.failure(SyncAccountError.appleSignInFailed)) }
        finish(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        finish(.failure(cancelled ? SyncAccountError.appleSignInCancelled : SyncAccountError.appleSignInFailed))
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
#endif
