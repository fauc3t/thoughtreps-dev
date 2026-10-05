import CryptoKit
import Foundation
import Testing
@testable import ThoughtReps

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func paths(_ path: String) -> [URLRequest] { requests.filter { $0.url?.lastPathComponent == path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class FakeAttest: AttestService, @unchecked Sendable {
    let isSupported: Bool
    private let lock = NSLock()
    private var keyCount = 0
    private(set) var attestHashes: [Data] = []
    private(set) var assertionHashes: [Data] = []
    var attestFails = false

    init(isSupported: Bool = true) { self.isSupported = isSupported }

    func generateKey() async throws -> String {
        lock.withLock { keyCount += 1; return "key\(keyCount)" }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if attestFails { throw APIError.attestationFailed }
        lock.withLock { attestHashes.append(clientDataHash) }
        return Data("attestation-\(keyId)".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { assertionHashes.append(clientDataHash) }
        return Data("assertion-\(keyId)".utf8)
    }
}

private final class MemoryKeyStore: KeyIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    var loadFails = false
    var saveFails = false
    func load() throws -> String? {
        if loadFails { throw KeychainStatusError(status: -25308) }
        return lock.withLock { value }
    }
    func save(_ keyId: String) throws {
        if saveFails { throw KeychainStatusError(status: -25308) }
        lock.withLock { value = keyId }
    }
    func clear() { lock.withLock { value = nil } }
}

private let challenge = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP-"

private struct Ping: Encodable { let challenge: String; let text: String }
private struct Pong: Decodable { let ok: Bool }

private func standardHandler(
    ping: @escaping @Sendable (URLRequest) -> (Int, String) = { _ in (200, #"{"ok":true}"#) },
    devices: @escaping @Sendable (URLRequest) -> (Int, String) = { _ in (200, #"{"registered":true}"#) }
) -> FakeTransport.Handler {
    { request in
        switch request.url?.lastPathComponent {
        case "challenge": (200, #"{"challenge":"\#(challenge)","expiresAt":"2026-01-01T00:00:00.000Z"}"#)
        case "devices": devices(request)
        default: ping(request)
        }
    }
}

private func makeClient(
    transport: FakeTransport, attest: FakeAttest = FakeAttest(), store: MemoryKeyStore = MemoryKeyStore()
) -> AppAttestClient {
    AppAttestClient(baseURL: URL(string: "https://example.test/api/v1")!, transport: transport, attest: attest, keyStore: store)
}

private func post(_ client: AppAttestClient) async throws -> Pong {
    try await client.signedPost("ping", body: { Ping(challenge: $0, text: "hi") }, response: Pong.self)
}

@Suite("AppAttestClient")
struct AppAttestClientTests {
    @Test func attestationHashIsSHA256OfChallengeUTF8() async throws {
        let attest = FakeAttest()
        let client = makeClient(transport: FakeTransport(standardHandler()), attest: attest)
        _ = try await post(client)
        #expect(attest.attestHashes == [Data(SHA256.hash(data: Data(challenge.utf8)))])
    }

    @Test func assertionHashCoversExactBodyBytesAndHeadersAreSet() async throws {
        let attest = FakeAttest()
        let transport = FakeTransport(standardHandler())
        let client = makeClient(transport: transport, attest: attest)
        _ = try await post(client)

        let request = try #require(transport.paths("ping").first)
        let body = try #require(request.httpBody)
        #expect(attest.assertionHashes == [Data(SHA256.hash(data: body))])
        #expect(request.value(forHTTPHeaderField: "x-tr-key-id") == "key1")
        #expect(request.value(forHTTPHeaderField: "x-tr-assertion") == Data("assertion-key1".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["challenge"] == challenge)
    }

    @Test func registrationBodyAndPersistence() async throws {
        let transport = FakeTransport(standardHandler())
        let store = MemoryKeyStore()
        _ = try await post(makeClient(transport: transport, store: store))
        let body = try #require(transport.paths("devices").first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["keyId"] == "key1")
        #expect(json["challenge"] == challenge)
        #expect(json["attestation"] == Data("attestation-key1".utf8).base64EncodedString())
        #expect((try? store.load()) == "key1")
    }

    @Test func registrationNotPersistedOnFailure() async {
        let store = MemoryKeyStore()
        let transport = FakeTransport(standardHandler(devices: { _ in (401, #"{"error":"attestation_invalid","message":"x"}"#) }))
        await #expect(throws: APIError.attestationInvalid) { try await post(makeClient(transport: transport, store: store)) }
        #expect((try? store.load()) == nil)
    }

    @Test func attestFailureIsNotPersisted() async {
        let store = MemoryKeyStore()
        let attest = FakeAttest()
        attest.attestFails = true
        await #expect(throws: APIError.attestationFailed) {
            try await post(makeClient(transport: FakeTransport(standardHandler()), attest: attest, store: store))
        }
        #expect((try? store.load()) == nil)
    }

    @Test func keychainReadFailureDoesNotRegister() async {
        let store = MemoryKeyStore("k")
        store.loadFails = true
        let transport = FakeTransport(standardHandler())
        await #expect(throws: APIError.keychainFailed) { try await post(makeClient(transport: transport, store: store)) }
        #expect(transport.requests.isEmpty)
    }

    @Test func keychainWriteFailureSurfaces() async {
        let store = MemoryKeyStore()
        store.saveFails = true
        await #expect(throws: APIError.keychainFailed) {
            try await post(makeClient(transport: FakeTransport(standardHandler()), store: store))
        }
    }

    @Test func storedKeySkipsRegistration() async throws {
        let transport = FakeTransport(standardHandler())
        _ = try await post(makeClient(transport: transport, store: MemoryKeyStore("stored")))
        #expect(transport.paths("devices").isEmpty)
        #expect(transport.paths("ping").first?.value(forHTTPHeaderField: "x-tr-key-id") == "stored")
    }

    @Test func reregistersOnceWhenDeviceUnknown() async throws {
        let calls = LockedCounter()
        let transport = FakeTransport(standardHandler(ping: { _ in
            calls.increment() == 1 ? (401, #"{"error":"assertion_invalid","message":"Unknown device"}"#) : (200, #"{"ok":true}"#)
        }))
        let store = MemoryKeyStore("old")
        let attest = FakeAttest()
        let client = makeClient(transport: transport, attest: attest, store: store)
        _ = try await post(client)
        #expect((try? store.load()) == "key1")
        #expect(transport.paths("devices").count == 1)
        #expect(transport.paths("ping").count == 2)
    }

    @Test func reregistersOnlyOnce() async {
        let transport = FakeTransport(standardHandler(ping: { _ in (401, #"{"error":"assertion_invalid","message":"x"}"#) }))
        await #expect(throws: APIError.assertionInvalid) { try await post(makeClient(transport: transport, store: MemoryKeyStore("old"))) }
        #expect(transport.paths("devices").count == 1)
        #expect(transport.paths("ping").count == 2)
    }

    @Test func concurrentCallsRegisterOnce() async throws {
        let transport = FakeTransport(standardHandler())
        let client = makeClient(transport: transport)
        async let a = post(client)
        async let b = post(client)
        _ = try await (a, b)
        #expect(transport.paths("devices").count == 1)
    }

    @Test func unsupportedDevice() async {
        let transport = FakeTransport(standardHandler())
        await #expect(throws: APIError.unsupported) {
            try await post(makeClient(transport: transport, attest: FakeAttest(isSupported: false)))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        (400, #"{"error":"bad_request","message":"x"}"#, APIError.badRequest),
        (401, #"{"error":"challenge_invalid","message":"x"}"#, APIError.challengeInvalid),
        (429, #"{"error":"rate_limited","message":"x"}"#, APIError.rateLimited),
        (429, "", APIError.rateLimited),
        (500, #"{"message":"internal error"}"#, APIError.server(status: 500)),
        (502, "<html>", APIError.server(status: 502)),
    ])
    func errorMapping(status: Int, body: String, expected: APIError) async {
        let transport = FakeTransport(standardHandler(ping: { _ in (status, body) }))
        await #expect(throws: expected) { try await post(makeClient(transport: transport, store: MemoryKeyStore("k"))) }
    }

    @Test func offlineAndOtherNetworkErrors() async {
        let offline = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: APIError.offline) { try await post(makeClient(transport: offline)) }
        let other = FakeTransport { _ in throw URLError(.secureConnectionFailed) }
        await #expect(throws: APIError.network) { try await post(makeClient(transport: other)) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
