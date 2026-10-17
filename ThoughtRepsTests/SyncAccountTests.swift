#if DEBUG
import CryptoKit
import DeviceCheck
import Foundation
import Testing
import os
@testable import ThoughtReps

private final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, _ challenge: Int) async throws -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var challenges = 0
    private let handler: Handler

    init(_ handler: @escaping Handler = { _, _ in (500, "{}") }) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var paths: [String] { requests.map { $0.url!.path.replacingOccurrences(of: "/api/v1/", with: "") } }
    func requests(to path: String) -> [URLRequest] { requests.filter { $0.url!.path.hasSuffix("/" + path) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let number: Int = lock.withLock {
            _requests.append(request)
            if request.url!.path.hasSuffix("app-attest/challenge") { challenges += 1 }
            return challenges
        }
        let (status, body): (Int, String)
        if request.url!.path.hasSuffix("app-attest/challenge") {
            (status, body) = (200, #"{"challenge":"challenge-\#(number)","expiresAt":1768478700000,"serverTime":1768478400000}"#)
        } else {
            (status, body) = try await handler(request, number)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class FakeAttest: AttestService, @unchecked Sendable {
    let isSupported = true
    private let lock = NSLock()
    private var _attestHashes: [Data] = []
    private var _assertionHashes: [Data] = []
    var attestHashes: [Data] { lock.withLock { _attestHashes } }
    var assertionHashes: [Data] { lock.withLock { _assertionHashes } }

    private var keyCount = 0

    func generateKey() async throws -> String {
        lock.withLock { keyCount += 1; return "key-\(keyCount)" }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { _attestHashes.append(clientDataHash) }
        return Data("attestation".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { _assertionHashes.append(clientDataHash) }
        if lock.withLock({ invalidKeys.contains(keyId) }) { throw DCError(.invalidKey) }
        return Data("assertion-\(keyId)".utf8)
    }

    /// Keys App Attest no longer has.
    var invalidKeys: Set<String> = []
}

private final class MemoryKeyIdStore: KeyIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() throws -> String? { lock.withLock { value } }
    func save(_ keyId: String) throws { lock.withLock { value = keyId } }
    func clear() { lock.withLock { value = nil } }
}

private final class MemoryCredentials: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncCredentials?
    init(_ value: SyncCredentials? = nil) { self.value = value }
    func load() throws -> SyncCredentials? { lock.withLock { value } }
    func save(_ credentials: SyncCredentials) throws { lock.withLock { value = credentials } }
    func clear() { lock.withLock { value = nil } }
}

private final class FakeApple: AppleSignIn, @unchecked Sendable {
    private let lock = NSLock()
    private var _nonces: [String] = []
    var nonces: [String] { lock.withLock { _nonces } }

    func identityToken(nonce: String) async throws -> String {
        lock.withLock { _nonces.append(nonce); return "apple-token-\(_nonces.count)" }
    }
}

private let fixedKey = Data(0..<32)
private let sessionJSON = #"{"token":"session-token","expiresAt":1768482000000}"#

private func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

private func accountJSON(vault: String?) -> String {
    let vaultField = vault.map { "\"\($0)\"" } ?? "null"
    return #"{"userId":"user-1","vaultId":\#(vaultField),"session":\#(sessionJSON),"serverTime":1768478400000}"#
}

private func errorJSON(_ code: String) -> String { #"{"error":"\#(code)","message":"nope","serverTime":1768478400000}"# }

private let apiURL = URL(string: "https://sync.test/api/v1")!

@Suite("Sync account sign-in")
fileprivate struct SyncAccountServiceTests {
    struct Rig {
        var http: FakeHTTP
        var attest = FakeAttest()
        var keys = MemoryKeyIdStore()
        var apple = FakeApple()
        var credentials = MemoryCredentials()

        var service: SyncAccountService {
            SyncAccountService(
                api: SyncAccountAPI(baseURL: apiURL, transport: http, attest: attest, keyStore: keys), apple: apple,
                credentials: credentials, makeVaultKey: { fixedKey }
            )
        }
    }

    static func account(vault: String? = nil, signIn: @escaping @Sendable (Int) -> (Int, String) = { _ in (200, accountJSON(vault: nil)) }) -> FakeHTTP {
        let signIns = OSAllocatedUnfairLock(initialState: 0)
        return FakeHTTP { request, _ in
            switch request.url!.lastPathComponent {
            case "register": return (200, #"{"registered":true,"serverTime":1}"#)
            case "sign-in-with-apple":
                let count = signIns.withLock { $0 += 1; return $0 }
                return signIn(count)
            case "vaults": return (200, #"{"vaultId":"vault-1","epoch":1,"session":{"token":"vault-token","expiresAt":1768482000000},"serverTime":1}"#)
            default: return (500, "{}")
            }
        }
    }

    @Test func createsAVaultInOrderWithTheSignedBodiesAndTheVerifier() async throws {
        let rig = Rig(http: Self.account())
        let outcome = try await rig.service.signInAndCreateVault()

        #expect(rig.http.paths == [
            "devices/app-attest/challenge", "devices/app-attest/register", "devices/app-attest/challenge",
            "accounts/sign-in-with-apple", "vaults",
        ])
        let register = try #require(rig.http.requests(to: "register").first)
        let registered = try JSONDecoder().decode(SyncHTTPWireV1.DeviceRegisterRequest.self, from: try #require(register.httpBody))
        #expect(registered == SyncHTTPWireV1.DeviceRegisterRequest(keyId: "key-1", attestation: Data("attestation".utf8).base64EncodedString(), challenge: "challenge-1"))
        #expect(rig.attest.attestHashes == [Data(SHA256.hash(data: Data("challenge-1".utf8)))])
        #expect(try rig.keys.load() == "key-1")

        let signIn = try #require(rig.http.requests(to: "sign-in-with-apple").first)
        let signInBody = try #require(signIn.httpBody)
        let sent = try JSONDecoder().decode(SyncHTTPWireV1.SignInWithAppleRequest.self, from: signInBody)
        #expect(sent == SyncHTTPWireV1.SignInWithAppleRequest(challenge: "challenge-2", identityToken: "apple-token-1"))
        #expect(rig.apple.nonces == [hex(SHA256.hash(data: Data("challenge-2".utf8)))])
        #expect(rig.attest.assertionHashes == [Data(SHA256.hash(data: signInBody))])
        #expect(signIn.value(forHTTPHeaderField: "x-tr-key-id") == "key-1")
        #expect(signIn.value(forHTTPHeaderField: "x-tr-assertion") == Data("assertion-key-1".utf8).base64EncodedString())

        let create = try #require(rig.http.requests(to: "vaults").first)
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(create.value(forHTTPHeaderField: "x-tr-key-id") == nil)
        let verifier = try JSONDecoder().decode(SyncHTTPWireV1.CreateAccountVaultRequest.self, from: try #require(create.httpBody)).kAuthVerifier
        #expect(verifier == (try SyncKeys(vaultKey: fixedKey)).authVerifier)

        let held = SyncCredentials(vaultKey: fixedKey, vaultID: "vault-1", userID: "user-1")
        #expect(outcome == .vaultCreated(held, SyncHTTPWireV1.SessionToken(token: "vault-token", expiresAt: 1_768_482_000_000)))
        #expect(try rig.credentials.load() == held)
    }

    @Test func theVerifierMatchesAnIndependentComputation() throws {
        // HKDF-SHA256 (zero salt, info "thoughtreps.sync.v1.auth") of the key 0...31, hashed and base64-encoded, computed
        // outside this code base.
        #expect(try SyncKeys(vaultKey: fixedKey).authVerifier == "H5Ny+/IOu8S7n8bGs4PeY9NSBHjMrKsMNfG5LyS0RJY=")
    }

    @Test func aRegisteredKeyIsNotRegisteredAgain() async throws {
        var rig = Rig(http: Self.account())
        rig.keys = MemoryKeyIdStore("key-9")
        _ = try await rig.service.signInAndCreateVault()
        #expect(rig.http.paths == ["devices/app-attest/challenge", "accounts/sign-in-with-apple", "vaults"])
        #expect(rig.attest.attestHashes.isEmpty)
    }

    @Test func aRejectedIdentityTokenIsRetriedOnceWithAFreshChallengeAndToken() async throws {
        let rig = Rig(http: Self.account { count in count == 1 ? (401, errorJSON("identity_token_invalid")) : (200, accountJSON(vault: nil)) })
        let outcome = try await rig.service.signInAndCreateVault()
        guard case .vaultCreated = outcome else { Issue.record("\(outcome)"); return }
        #expect(rig.http.requests(to: "sign-in-with-apple").count == 2)
        #expect(rig.apple.nonces == [hex(SHA256.hash(data: Data("challenge-2".utf8))), hex(SHA256.hash(data: Data("challenge-3".utf8)))])
        let bodies = try rig.http.requests(to: "sign-in-with-apple").map {
            try JSONDecoder().decode(SyncHTTPWireV1.SignInWithAppleRequest.self, from: try #require($0.httpBody))
        }
        #expect(bodies.map(\.identityToken) == ["apple-token-1", "apple-token-2"])
    }

    @Test func aSecondRejectedIdentityTokenIsAnError() async {
        let rig = Rig(http: Self.account { _ in (401, errorJSON("identity_token_invalid")) })
        await #expect(throws: SyncAccountError.server(status: 401, code: "identity_token_invalid")) { try await rig.service.signInAndCreateVault() }
        #expect(rig.http.requests(to: "sign-in-with-apple").count == 2)
        #expect(rig.http.requests(to: "vaults").isEmpty)
    }

    @Test func aDeviceInAnotherAccountsVaultStops() async throws {
        let rig = Rig(http: Self.account { _ in (409, errorJSON("device_in_vault")) })
        #expect(try await rig.service.signInAndCreateVault() == .deviceInVault)
        #expect(rig.http.requests(to: "vaults").isEmpty)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func anAccountWithAVaultThisDeviceHasNoKeyForStops() async throws {
        let rig = Rig(http: Self.account { _ in (200, accountJSON(vault: "vault-1")) })
        #expect(try await rig.service.signInAndCreateVault() == .accountHasVault)
        #expect(rig.http.requests(to: "vaults").isEmpty)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func aKeyForAnotherVaultOrUserIsNotTheAccountsKey() async throws {
        for held in [
            SyncCredentials(vaultKey: fixedKey, vaultID: "other", userID: "user-1"),
            SyncCredentials(vaultKey: fixedKey, vaultID: "vault-1", userID: "someone"),
        ] {
            var rig = Rig(http: Self.account { _ in (200, accountJSON(vault: "vault-1")) })
            rig.credentials = MemoryCredentials(held)
            #expect(try await rig.service.signInAndCreateVault() == .accountHasVault)
            #expect(try rig.credentials.load() == held, "nothing is overwritten")
        }
    }

    @Test func signingInAgainWithTheHeldKeyAdoptsTheSession() async throws {
        let held = SyncCredentials(vaultKey: fixedKey, vaultID: "vault-1", userID: "user-1")
        var rig = Rig(http: Self.account { _ in (200, accountJSON(vault: "vault-1")) })
        rig.credentials = MemoryCredentials(held)
        #expect(try await rig.service.signInAndCreateVault() == .signedIn(held, SyncHTTPWireV1.SessionToken(token: "session-token", expiresAt: 1_768_482_000_000)))
        #expect(rig.http.requests(to: "vaults").isEmpty)
    }

    @Test func aVaultThatAlreadyExistsStopsWithoutStoringAKey() async throws {
        let http = FakeHTTP { request, _ in
            switch request.url!.lastPathComponent {
            case "register": (200, #"{"registered":true}"#)
            case "sign-in-with-apple": (200, accountJSON(vault: nil))
            default: (409, errorJSON("vault_exists"))
            }
        }
        let rig = Rig(http: http)
        #expect(try await rig.service.signInAndCreateVault() == .accountHasVault)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func aKeyAppAttestNoLongerHasIsReplacedOnceAndTheSignInRetried() async throws {
        var rig = Rig(http: Self.account())
        rig.keys = MemoryKeyIdStore("old")
        rig.attest.invalidKeys = ["old"]
        let outcome = try await rig.service.signInAndCreateVault()
        guard case .vaultCreated = outcome else { Issue.record("\(outcome)"); return }
        #expect(rig.http.paths == [
            "devices/app-attest/challenge", "devices/app-attest/challenge", "devices/app-attest/register",
            "accounts/sign-in-with-apple", "vaults",
        ])
        #expect(rig.http.requests(to: "sign-in-with-apple").first?.value(forHTTPHeaderField: "x-tr-key-id") == "key-1")
        #expect(try rig.keys.load() == "key-1")
    }

    @Test func aKeyTheServerDoesNotKnowIsReplacedOnceAndTheSignInRetried() async throws {
        var rig = Rig(http: Self.account { count in count == 1 ? (401, errorJSON("assertion_invalid")) : (200, accountJSON(vault: nil)) })
        rig.keys = MemoryKeyIdStore("old")
        let outcome = try await rig.service.signInAndCreateVault()
        guard case .vaultCreated = outcome else { Issue.record("\(outcome)"); return }
        let signIns = rig.http.requests(to: "sign-in-with-apple")
        #expect(signIns.map { $0.value(forHTTPHeaderField: "x-tr-key-id") } == ["old", "key-1"])
        #expect(signIns[0].httpBody == signIns[1].httpBody)
        #expect(rig.http.requests(to: "register").count == 1)
        #expect(try rig.keys.load() == "key-1")
    }

    @Test func aSecondFailureAfterReRegisteringSurfacesWithoutLooping() async throws {
        var rig = Rig(http: Self.account { _ in (401, errorJSON("assertion_invalid")) })
        rig.keys = MemoryKeyIdStore("old")
        await #expect(throws: SyncAccountError.server(status: 401, code: "assertion_invalid")) { try await rig.service.signInAndCreateVault() }
        #expect(rig.http.requests(to: "sign-in-with-apple").count == 2)
        #expect(rig.http.requests(to: "register").count == 1)

        var gone = Rig(http: Self.account())
        gone.keys = MemoryKeyIdStore("old")
        gone.attest.invalidKeys = ["old", "key-1"]
        await #expect(throws: SyncAccountError.staleKey) { try await gone.service.signInAndCreateVault() }
        #expect(gone.http.requests(to: "register").count == 1)
        #expect(gone.http.requests(to: "sign-in-with-apple").isEmpty)
    }

    @MainActor
    @Test func forgettingTheAccountClearsTheVaultKeyAndTheDeviceKey() async throws {
        let credentials = MemoryCredentials(SyncCredentials(vaultKey: fixedKey, vaultID: "vault-1", userID: "user-1"))
        let keys = MemoryKeyIdStore("key-1")
        await SyncDebugSession.forgetAccount(state: SyncState(location: .inMemory), credentials: credentials, attestKeys: keys)
        #expect(try credentials.load() == nil)
        #expect(try keys.load() == nil)
    }

    @Test func aFailedAppleSignInSendsNothingToTheAccountRoutes() async {
        struct Declines: AppleSignIn {
            func identityToken(nonce: String) async throws -> String { throw SyncAccountError.appleSignInCancelled }
        }
        let rig = Rig(http: Self.account())
        let service = SyncAccountService(
            api: SyncAccountAPI(baseURL: apiURL, transport: rig.http, attest: rig.attest, keyStore: rig.keys), apple: Declines(), credentials: rig.credentials
        )
        await #expect(throws: SyncAccountError.appleSignInCancelled) { try await service.signInAndCreateVault() }
        #expect(rig.http.requests(to: "sign-in-with-apple").isEmpty)
    }

    @Test func newVaultKeysAreRandom() {
        let service = SyncAccountService(api: SyncAccountAPI(baseURL: apiURL), apple: FakeApple(), credentials: MemoryCredentials())
        let first = service.makeVaultKey()
        #expect(first.count == SyncKeys.keyLength && first != service.makeVaultKey())
    }
}

@Suite("Sync credentials in the Keychain")
struct KeychainSyncCredentialStoreTests {
    @Test func roundTripsOneNonSynchronizableThisDeviceOnlyItem() throws {
        let service = "com.thoughtreps.tests.\(UUID().uuidString)"
        let store = KeychainSyncCredentialStore(service: service)
        defer { store.clear() }
        #expect(try store.load() == nil)

        let held = SyncCredentials(vaultKey: fixedKey, vaultID: "vault-1", userID: "user-1")
        try store.save(held)
        #expect(try store.load() == held)
        let replacement = SyncCredentials(vaultKey: Data(repeating: 7, count: 32), vaultID: "vault-2", userID: "user-1")
        try store.save(replacement)
        #expect(try store.load() == replacement)

        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let items = try #require(item as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrSynchronizable as String] as? Bool != true)
        #expect(items.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        store.clear()
        #expect(try store.load() == nil)
    }
}

@Suite("Sync session provider")
fileprivate struct SyncSessionProviderTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double
        init(_ seconds: Double) { self.seconds = seconds }
        var now: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
        func advance(_ by: Double) { lock.withLock { seconds += by } }
    }

    /// Each session lasts an hour from the moment the server issues it (the clock at the time of the request).
    static func rig(clock: Clock, delay: Duration = .zero, vault: String? = "vault-1") -> (SyncSessionProvider, FakeHTTP, FakeAttest) {
        let http = FakeHTTP { request, number in
            if delay != .zero { try await Task.sleep(for: delay) }
            let expires = Int64(clock.now.timeIntervalSince1970 * 1000) + 3_600_000
            return (200, #"{"userId":"user-1","vaultId":\#(vault.map { "\"\($0)\"" } ?? "null"),"session":{"token":"token-\#(number)","expiresAt":\#(expires)},"serverTime":1}"#)
        }
        let attest = FakeAttest()
        let api = SyncAccountAPI(baseURL: apiURL, transport: http, attest: attest, keyStore: MemoryKeyIdStore("key-1"))
        return (SyncSessionProvider(api: api, vaultID: "vault-1", serverNow: { clock.now }), http, attest)
    }

    @Test func mintsASignedSessionOnFirstUse() async throws {
        let (provider, http, attest) = Self.rig(clock: Clock(1_768_478_400))
        #expect(try await provider.token() == "token-1")
        #expect(http.paths == ["devices/app-attest/challenge", "sessions/app-attest"])
        let request = try #require(http.requests(to: "sessions/app-attest").first)
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(SyncHTTPWireV1.SessionRequest.self, from: body) == SyncHTTPWireV1.SessionRequest(challenge: "challenge-1"))
        #expect(attest.assertionHashes == [Data(SHA256.hash(data: body))])
        #expect(request.value(forHTTPHeaderField: "x-tr-key-id") == "key-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keepsTheSessionUntilFiveMinutesBeforeItExpires() async throws {
        let clock = Clock(1_768_478_400)
        let (provider, http, _) = Self.rig(clock: clock)
        #expect(try await provider.token() == "token-1")
        clock.advance(3_600 - 301)
        #expect(try await provider.token() == "token-1")
        #expect(http.requests(to: "sessions/app-attest").count == 1)
        clock.advance(2)
        #expect(try await provider.token() == "token-2")
        #expect(http.requests(to: "sessions/app-attest").count == 2)
    }

    @Test func aTokenAdoptedFromSignInIsUsedWithoutMinting() async throws {
        let clock = Clock(1_768_478_400)
        let (provider, http, _) = Self.rig(clock: clock)
        await provider.adopt(SyncHTTPWireV1.SessionToken(token: "adopted", expiresAt: 1_768_478_400_000 + 3_600_000))
        #expect(try await provider.token() == "adopted")
        #expect(http.requests.isEmpty)
    }

    @Test func concurrentCallersShareOneMint() async throws {
        let (provider, http, _) = Self.rig(clock: Clock(1_768_478_400), delay: .milliseconds(50))
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await provider.token() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(tokens).count == 1)
        #expect(http.requests(to: "sessions/app-attest").count == 1)
    }

    @Test func refreshAfterARejectionMintsANewTokenOnlyOnce() async throws {
        let clock = Clock(1_768_478_400)
        let (provider, http, _) = Self.rig(clock: clock)
        let first = try await provider.token()
        let second = try await provider.refresh(after: first)
        #expect(second != first)
        #expect(try await provider.refresh(after: first) == second, "another caller already replaced the rejected token")
        #expect(http.requests(to: "sessions/app-attest").count == 2)
    }

    @Test func aStaleDeviceKeyIsReplacedOnceWhenMinting() async throws {
        let http = FakeHTTP { request, number in
            request.url!.lastPathComponent == "register"
                ? (200, #"{"registered":true,"serverTime":1}"#)
                : (200, #"{"userId":"user-1","vaultId":"vault-1","session":{"token":"token-\#(number)","expiresAt":9999999999999},"serverTime":1}"#)
        }
        let attest = FakeAttest()
        attest.invalidKeys = ["old"]
        let keys = MemoryKeyIdStore("old")
        let provider = SyncSessionProvider(
            api: SyncAccountAPI(baseURL: apiURL, transport: http, attest: attest, keyStore: keys), vaultID: "vault-1", serverNow: { Date() }
        )
        #expect(try await provider.token() == "token-2")
        #expect(http.requests(to: "register").count == 1)
        #expect(try keys.load() == "key-1")
    }

    @Test func aSessionWithoutThisVaultIsRefused() async {
        let (provider, _, _) = Self.rig(clock: Clock(1_768_478_400), vault: nil)
        await #expect(throws: SyncAccountError.server(status: 403, code: "forbidden")) { try await provider.token() }
    }

    @Test func noRegisteredKeyIsAnErrorBeforeAnyRequest() async {
        let http = FakeHTTP()
        let api = SyncAccountAPI(baseURL: apiURL, transport: http, attest: FakeAttest(), keyStore: MemoryKeyIdStore())
        let provider = SyncSessionProvider(api: api, vaultID: "vault-1", serverNow: { Date() })
        await #expect(throws: SyncAccountError.notRegistered) { try await provider.token() }
        #expect(http.requests.isEmpty)
    }
}

private final class FakeSessionSource: SyncSessionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _rejected: [String] = []
    var tokenError: Error?
    var rejected: [String] { lock.withLock { _rejected } }

    func token() async throws -> String {
        if let tokenError { throw tokenError }
        return "t1"
    }

    func refresh(after rejected: String) async throws -> String {
        lock.withLock { _rejected.append(rejected) }
        return "t2"
    }
}

private final class BearerStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    static let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HTTP sync transport with a session", .serialized)
fileprivate struct HTTPSyncTransportSessionTests {
    static let head = #"{"headSeq":9,"epoch":1,"liveRecordCount":2,"serverTime":1}"#

    func transport(source: FakeSessionSource, handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> HTTPSyncTransport {
        BearerStubProtocol.handler = handler
        BearerStubProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BearerStubProtocol.self]
        return HTTPSyncTransport(
            baseURL: apiURL, vaultID: "vault-1", auth: .session(source), session: URLSession(configuration: configuration),
            sleep: { _ in }
        )
    }

    var requests: [URLRequest] { BearerStubProtocol.requests.withLock { $0 } }

    @Test func requestsCarryOnlyTheBearerToken() async throws {
        let transport = transport(source: FakeSessionSource()) { _ in (200, Self.head) }
        _ = try await transport.head()
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        #expect(request.value(forHTTPHeaderField: "x-tr-vault") == nil)
    }

    @Test func aRejectedTokenIsRefreshedAndTheRequestRetriedOnce() async throws {
        let source = FakeSessionSource()
        let transport = transport(source: source) { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer t2" ? (200, Self.head) : (401, errorJSON("unauthorized"))
        }
        #expect(try await transport.head().headSeq == 9)
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer t1", "Bearer t2"])
        #expect(source.rejected == ["t1"])
    }

    @Test func aSecondRejectionIsTheServersRefusal() async {
        let source = FakeSessionSource()
        let transport = transport(source: source) { _ in (401, errorJSON("unauthorized")) }
        await #expect(throws: SyncTransportError.refused(status: 401, message: "nope")) { try await transport.head() }
        #expect(requests.count == 2)
        #expect(source.rejected == ["t1"])
    }

    @Test func aPostIsRetriedAfterARefresh() async throws {
        let transport = transport(source: FakeSessionSource()) { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer t2" ? (200, #"{"headSeq":1,"seqs":{"a":1},"serverTime":1}"#) : (401, errorJSON("unauthorized"))
        }
        let result = try await transport.push([PushRecord(recordKey: "a", baseSeq: nil, payload: Data("x".utf8), deleted: false)], epoch: 1)
        #expect(result == .ok(seqs: ["a": 1], headSeq: 1))
        #expect(requests.count == 2)
    }

    @Test func aSessionThatCantBeMintedMapsToATransportError() async {
        let source = FakeSessionSource()
        source.tokenError = SyncAccountError.server(status: 403, code: "assertion_invalid")
        let refused = transport(source: source) { _ in (200, Self.head) }
        await #expect(throws: SyncTransportError.refused(status: 403, message: "assertion_invalid")) { try await refused.head() }

        source.tokenError = SyncAccountError.offline
        await #expect(throws: SyncTransportError.unavailable) { try await refused.head() }
        #expect(requests.isEmpty)
    }

    @Test func presignedStorageRequestsCarryNoSessionHeaders() async throws {
        let transport = transport(source: FakeSessionSource()) { request in
            if request.httpMethod == "PUT" { return (200, "") }
            return (200, #"{"uploads":[{"name":"b","url":"https://s3.test/b","headers":{"x-amz-checksum-sha256":"abc"}}],"present":[],"serverTime":1}"#)
        }
        try await transport.putBlob(name: "b", data: Data("blob".utf8), epoch: 1)
        let put = try #require(requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.host == "s3.test")
        #expect(put.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(put.value(forHTTPHeaderField: "x-tr-vault") == nil)
        #expect(put.value(forHTTPHeaderField: "x-amz-checksum-sha256") == "abc")
    }

    @Test func theDevSecretStillSendsItsOwnHeaders() async throws {
        BearerStubProtocol.handler = { _ in (200, Self.head) }
        BearerStubProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BearerStubProtocol.self]
        let transport = HTTPSyncTransport(baseURL: apiURL, vaultID: "vault-1", auth: .devSecret("s3cret"), session: URLSession(configuration: configuration))
        _ = try await transport.head()
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Dev s3cret")
        #expect(request.value(forHTTPHeaderField: "x-tr-vault") == "vault-1")
    }
}
#endif
