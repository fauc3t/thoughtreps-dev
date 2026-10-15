import Foundation
import Testing
import os
@testable import ThoughtReps

/// Answers requests from a closure, so `HTTPSyncTransport` is tested without a server.
final class SyncStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var failure: URLError?
        var headers: [String: String] = [:]

        static func json(_ status: Int, _ body: String) -> Reply { Reply(status: status, body: body, failure: nil) }
        static func failing(_ code: URLError.Code) -> Reply { Reply(status: 0, body: "", failure: URLError(code)) }
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    static let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// A body set with `httpBody` reaches the protocol as a stream.
    private static func withBody(_ request: URLRequest) -> URLRequest {
        var seen = request
        guard seen.httpBody == nil, let stream = request.httpBodyStream else { return seen }
        stream.open()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        stream.close()
        seen.httpBody = data
        return seen
    }

    override func startLoading() {
        let seen = Self.withBody(request)
        Self.requests.withLock { $0.append(seen) }
        guard let reply = Self.handler?(seen) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"].merging(reply.headers) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HTTP sync transport", .serialized)
struct HTTPSyncTransportTests {
    let baseURL = URL(string: "http://127.0.0.1:8787/api/v1")!

    func transport(
        attempts: Int = 3, offset: ServerClockOffset? = nil, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        handler: @escaping @Sendable (URLRequest) -> SyncStubURLProtocol.Reply
    ) -> HTTPSyncTransport {
        SyncStubURLProtocol.handler = handler
        SyncStubURLProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubURLProtocol.self]
        return HTTPSyncTransport(
            baseURL: baseURL, vaultID: "v1", devSecret: "s3cret", session: URLSession(configuration: configuration), offset: offset,
            maxAttempts: attempts, now: now, sleep: sleep
        )
    }

    var requests: [URLRequest] { SyncStubURLProtocol.requests.withLock { $0 } }

    @Test func requestsCarryTheDevAuthAndVaultHeaders() async throws {
        let transport = transport { _ in .json(200, #"{"headSeq":9,"epoch":1,"liveRecordCount":2,"serverTime":1}"#) }
        let head = try await transport.head()
        #expect(head == SyncHead(headSeq: 9, epoch: 1, liveRecordCount: 2))
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/api/v1/head")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Dev s3cret")
        #expect(request.value(forHTTPHeaderField: "x-tr-vault") == "v1")
    }

    @Test func aPushIsSentWithAnExplicitNullBaseSeq() async throws {
        let transport = transport { _ in .json(200, #"{"headSeq":2,"seqs":{"a":1,"b":2},"serverTime":1}"#) }
        let result = try await transport.push([
            PushRecord(recordKey: "a", baseSeq: nil, payload: Data("hi".utf8), deleted: false),
            PushRecord(recordKey: "b", baseSeq: 4, payload: Data(), deleted: true),
        ], epoch: 3)
        #expect(result == .ok(seqs: ["a": 1, "b": 2], headSeq: 2))
        let body = try #require(requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
        let expected: NSDictionary = [
            "epoch": 3,
            "records": [
                ["key": "a", "baseSeq": NSNull(), "deleted": false, "payload": "aGk="],
                ["key": "b", "baseSeq": 4, "deleted": true, "payload": ""],
            ],
        ]
        #expect(sent == expected)
        #expect(requests.first?.httpMethod == "POST")
    }

    @Test func aPullAsksForTheCursorLimitAndFullResync() async throws {
        let transport = transport { _ in .json(200, #"{"records":[{"key":"a","seq":5,"deleted":false,"payload":"aGk="}],"nextSeq":5,"headSeq":7,"more":true,"epoch":2,"serverTime":1}"#) }
        let result = try await transport.pull(after: 4, limit: 200, fullResync: true)
        let query = URLComponents(url: try #require(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        #expect(query == ["since": "4", "limit": "200", "fullResync": "true"])
        #expect(result == .page(PullPage(
            records: [PulledRecord(recordKey: "a", seq: 5, payload: Data("hi".utf8), deleted: false)], nextSeq: 5, headSeq: 7, epoch: 2, hasMore: true
        )))
    }

    @Test func aConflictBodyIsAResultAndAnEpochBodyIsAnError() async throws {
        let conflict = transport { _ in .json(409, #"{"error":"conflict","conflicts":["a","b"],"serverTime":1}"#) }
        let record = PushRecord(recordKey: "a", baseSeq: nil, payload: Data(), deleted: false)
        #expect(try await conflict.push([record], epoch: 1) == .conflict(keys: ["a", "b"]))
        let epoch = transport { _ in .json(409, #"{"error":"epoch_changed","epochChanged":true,"epoch":4,"serverTime":1}"#) }
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) { try await epoch.push([record], epoch: 1) }
    }

    @Test func goneTooLargeAndRefusedMapToTheirCases() async throws {
        let gone = transport { _ in .json(410, #"{"error":"gone","message":"x","serverTime":1}"#) }
        #expect(try await gone.pull(after: 1, limit: 10, fullResync: false) == .gone)
        let large = transport { _ in .json(413, #"{"error":"too_large","message":"Push is too large","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.tooLarge) { try await large.push([], epoch: 1) }
        for (status, code) in [(400, "bad_request"), (401, "unauthorized"), (404, "not_found")] {
            let refused = transport { _ in .json(status, #"{"error":"\#(code)","message":"nope","serverTime":1}"#) }
            await #expect(throws: SyncTransportError.refused(status: status, message: "nope")) { try await refused.head() }
            #expect(requests.count == 1, "\(status) is not retried")
        }
        let forbidden = transport { _ in .json(403, #"{"error":"unauthorized","message":"no","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.refused(status: 403, message: "no")) { try await forbidden.head() }
        let wrongPlace = transport { _ in .json(409, #"{"error":"conflict","message":"x","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.unavailable, "a 4xx the call has no meaning for is a failed call, not a stop") { try await wrongPlace.head() }
        #expect(requests.count == 1)
    }

    @Test func aBusyServerOrAFailedConnectionIsRetriedThenUnavailable() async throws {
        let busy = transport { _ in .json(503, #"{"error":"busy","message":"The vault is busy, try again","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.unavailable) { try await busy.head() }
        #expect(requests.count == 3)
        let down = transport { _ in .failing(.cannotConnectToHost) }
        await #expect(throws: SyncTransportError.unavailable) { try await down.head() }
        #expect(requests.count == 3)
        let internalError = transport { _ in .json(500, #"{"message":"internal error","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.unavailable) { try await internalError.head() }
    }

    @Test func transientStatusesAreRetriedWithTheServersRetryAfterCapped() async throws {
        let pauses = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let record: @Sendable (Duration) async throws -> Void = { duration in pauses.withLock { $0.append(duration) } }
        for (status, header) in [(429, "7"), (429, "900"), (429, nil), (408, nil), (502, nil)] as [(Int, String?)] {
            pauses.withLock { $0 = [] }
            let transport = transport(sleep: record) { _ in
                SyncStubURLProtocol.Reply(status: status, body: "{}", failure: nil, headers: header.map { ["Retry-After": $0] } ?? [:])
            }
            await #expect(throws: SyncTransportError.unavailable, "\(status)") { try await transport.head() }
            #expect(requests.count == 3, "\(status) is tried 3 times")
            let expected: [Duration] = switch header {
            case "7": [.seconds(7), .seconds(7)]
            case "900": [.seconds(30), .seconds(30)]
            default: [.seconds(0.5), .seconds(1)]
            }
            #expect(pauses.withLock { $0 } == expected, "\(status) \(header ?? "no header")")
        }
    }

    @Test func aRetrySucceedsOnceTheServerRecovers() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let transport = transport { _ in
            calls.withLock { $0 += 1 }
            return calls.withLock { $0 } < 3 ? .failing(.timedOut) : .json(200, #"{"headSeq":1,"epoch":1,"liveRecordCount":1,"serverTime":1}"#)
        }
        #expect(try await transport.head().headSeq == 1)
        #expect(requests.count == 3)
    }

    @Test func anUndecodableAnswerIsUnavailable() async throws {
        let transport = transport { _ in .json(200, "<html>captive portal</html>") }
        await #expect(throws: SyncTransportError.unavailable) { try await transport.head() }
    }

    @Test func blobCallsAreUnsupported() async throws {
        let transport = transport { _ in .json(200, "{}") }
        #expect(!transport.supportsBlobs)
        await #expect(throws: SyncTransportError.unsupported) { try await transport.putBlob(name: "n", data: Data(), epoch: 1) }
        await #expect(throws: SyncTransportError.unsupported) { try await transport.getBlob(name: "n", maxBytes: 10) }
        await #expect(throws: SyncTransportError.unsupported) { try await transport.hasBlob(name: "n", epoch: 1) }
        #expect(requests.isEmpty)
    }

    @Test func everyResponseFeedsTheClockOffset() async throws {
        let suite = "HTTPSyncTransportTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OSAllocatedUnfairLock(initialState: 1_790_000_000.0)
        // Each request takes 0.2 s and the server's clock reads 10 s ahead of the midpoint.
        let transport = transport(offset: ServerClockOffset(defaults: defaults), now: { Date(timeIntervalSince1970: clock.withLock { $0 }) }) { _ in
            let sent = clock.withLock { $0 }
            clock.withLock { $0 += 0.2 }
            return .json(409, #"{"error":"conflict","conflicts":[],"serverTime":\#(Int64((sent + 10.1) * 1000))}"#)
        }
        let record = PushRecord(recordKey: "a", baseSeq: nil, payload: Data(), deleted: false)
        for _ in 0..<3 { _ = try await transport.push([record], epoch: 1) }
        #expect(abs(ServerClockOffset(defaults: defaults).current - 10) < 0.001, "errors carry serverTime too, and three agreeing samples are adopted")
    }
}
