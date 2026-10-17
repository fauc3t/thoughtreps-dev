#if DEBUG
import AuthenticationServices
import CryptoKit
import DeviceCheck
import Foundation
import UIKit
import os

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

    /// Like `signedPost`, but builds the body for each attempt from the key it is signed with, so a body that carries a
    /// single-use challenge or something bound to the key (a sealed device name) is never reused across keys.
    func signedPost<Body: Encodable, Response: Decodable>(
        _ path: String, keyId: String, makeBody: (_ keyId: String) async throws -> Body
    ) async throws -> Response {
        do {
            return try await signedPostOnce(path, keyId: keyId, body: try await makeBody(keyId))
        } catch let error as SyncAccountError where error.isStaleKey {
            keyStore.clear()
            let fresh = try await registeredKeyId()
            return try await signedPostOnce(path, keyId: fresh, body: try await makeBody(fresh))
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

    func put<Response: Decodable>(_ path: String, body: Data, bearer: String) async throws -> Response {
        var request = AppAttestClient.jsonRequest(url: baseURL.appending(path: path), body: body)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
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

/// What this device calls itself: in the Sync lab's prompts and, sealed, to the vault's other devices. `UIDevice.name` is a
/// generic "iPhone" or "iPad" without a special entitlement, so the idiom says the same.
enum SyncDeviceName {
    @MainActor static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
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
    var makePairingSecret: @Sendable () -> Data = { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    var deviceName: @Sendable () async -> String = { await MainActor.run { SyncDeviceName.current } }
    var now: @Sendable () -> Date = { Date() }
    /// The optional iCloud Keychain copy, written after a vault is created or joined.
    var iCloud: ICloudKeyCopy?

    private static let log = Logger(subsystem: "com.thoughtreps", category: "SyncAccountService")

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
        saveICloudCopy(held)
        await nameThisDevice(in: created.vaultId, key: key, session: created.session.token)
        return .vaultCreated(held, created.session)
    }

    /// The server mints the vault id, so the name can't be sealed into `POST /vaults`; it is set right after. A failure only
    /// leaves the device unnamed.
    private func nameThisDevice(in vaultID: String, key: Data, session: String) async {
        do {
            guard let keyId = try api.storedKeyId() else { return }
            let sealed = try SyncCrypto.sealDeviceName(await deviceName(), vaultID: vaultID, keyID: keyId, keys: SyncKeys(vaultKey: key))
            let pathKey = keyId.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let _: SyncHTTPWireV1.DeviceNameResponse = try await api.put(
                "vaults/\(vaultID)/devices/\(pathKey)", body: try SyncAccountAPI.encode(SyncHTTPWireV1.DeviceNameRequest(nameSealed: sealed)), bearer: session
            )
        } catch {
            Self.log.error("Naming this device failed: \(String(describing: error))")
        }
    }

    private func saveICloudCopy(_ held: SyncCredentials) {
        do { try iCloud?.saveIfEnabled(held) } catch { Self.log.error("Saving the iCloud Keychain copy failed: \(error)") }
    }

    // MARK: Joining

    /// What proves to the server that this device may join the vault.
    enum JoinProof: Equatable {
        /// K_auth, from the vault key: an iCloud Keychain copy or a recovery code.
        case vaultKey
        /// The secret of an open invitation from a device already in the vault.
        case invite(pairingSecret: Data)
    }

    struct Joined: Equatable {
        var credentials: SyncCredentials
        var session: SyncHTTPWireV1.SessionToken
    }

    /// Joins through `POST /pair`, signed with this device's key (registered first if it isn't yet) and carrying its sealed
    /// name. On success the key is stored here and, if the setting is on, in iCloud Keychain. A stale device key is replaced
    /// once, with a new challenge and a name sealed for the new key.
    func join(vaultID: String, vaultKey: Data, proof: JoinProof) async throws -> Joined {
        guard api.attest.isSupported else { throw SyncAccountError.unsupported }
        let keys = try SyncKeys(vaultKey: vaultKey)
        let keyId = try await api.registeredKeyId()
        let name = await deviceName()
        let answer: SyncHTTPWireV1.AccountSession = try await api.signedPost("pair", keyId: keyId, makeBody: { keyId in
            let challenge = try await api.challenge()
            let sealed = try SyncCrypto.sealDeviceName(name, vaultID: vaultID, keyID: keyId, keys: keys)
            switch proof {
            case .vaultKey:
                return SyncHTTPWireV1.PairRequest.kAuth(.init(vaultId: vaultID, challenge: challenge, kAuth: keys.authBytes, nameSealed: sealed))
            case .invite(let secret):
                return SyncHTTPWireV1.PairRequest.invite(.init(vaultId: vaultID, challenge: challenge, pairingSecret: secret, nameSealed: sealed))
            }
        })
        guard answer.vaultId == vaultID else { throw SyncAccountError.invalidResponse }
        let held = SyncCredentials(vaultKey: vaultKey, vaultID: vaultID, userID: answer.userId)
        do { try credentials.save(held) } catch { throw SyncAccountError.keychainFailed }
        saveICloudCopy(held)
        return Joined(credentials: held, session: answer.session)
    }

    func joinFromICloudKeychain() async throws -> Joined {
        guard let copy = try? iCloud?.load() else { throw SyncAccountError.keychainFailed }
        return try await join(vaultID: copy.vaultID, vaultKey: copy.vaultKey, proof: .vaultKey)
    }

    /// A wrong or mistyped code throws before anything is sent.
    func joinWithRecoveryCode(_ text: String) async throws -> Joined {
        let parsed = try SyncRecoveryCode.parse(text)
        return try await join(vaultID: parsed.vaultID, vaultKey: parsed.vaultKey, proof: .vaultKey)
    }

    func joinWithInvite(_ invite: SyncPairingInvite) async throws -> Joined {
        try await join(vaultID: invite.vaultID, vaultKey: invite.vaultKey, proof: .invite(pairingSecret: invite.pairingSecret))
    }

    // MARK: Inviting

    struct Invitation: Equatable {
        var invite: SyncPairingInvite
        /// When the server stops accepting it, on this device's clock (corrected by the server's `serverTime`).
        var expiresAt: Date
    }

    /// Opens a 10-minute, single-use invitation to the vault, from a device already in it.
    func createInvitation(credentials held: SyncCredentials, session: SyncSessionSource) async throws -> Invitation {
        let invite = SyncPairingInvite(vaultID: held.vaultID, pairingSecret: makePairingSecret(), vaultKey: held.vaultKey)
        let body = try SyncAccountAPI.encode(SyncHTTPWireV1.CreateInviteRequest(secretHash: invite.secretHash))
        let path = "vaults/\(held.vaultID)/invites"
        let response: SyncHTTPWireV1.CreateInviteResponse = try await withBearer(session) { token in
            try await api.post(path, body: body, bearer: token)
        }
        let received = now()
        let skew = response.serverTime.map { Double($0) / 1000 - received.timeIntervalSince1970 } ?? 0
        return Invitation(invite: invite, expiresAt: Date(timeIntervalSince1970: Double(response.expiresAt) / 1000 - skew))
    }

    private func withBearer<T>(_ session: SyncSessionSource, _ call: (String) async throws -> T) async throws -> T {
        let token = try await session.token()
        do {
            return try await call(token)
        } catch SyncAccountError.server(401, _) {
            return try await call(try await session.refresh(after: token))
        }
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
