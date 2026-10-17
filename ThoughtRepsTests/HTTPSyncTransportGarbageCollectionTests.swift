import CryptoKit
import Foundation
import Testing
import os
@testable import ThoughtReps

/// The garbage collection and quota half of `HTTPSyncTransport`, in the same suite as the rest because the stub protocol's
/// handler is shared.
extension HTTPSyncTransportTests {
    static let runID = "0123456789abcdef0123456789abcdef"
    static let liveList = Data((String(repeating: "A", count: 43) + "\n" + String(repeating: "B", count: 43) + "\n").utf8)
    static let listURL = "https://blobs.example.test/garbage-collection/v1/\(runID)?X-Amz-Signature=abc"

    static func liveListAnswer(checksum: String) -> String {
        #"{"runId":"\#(runID)","url":"\#(listURL)","headers":{"x-amz-checksum-sha256":"\#(checksum)"},"serverTime":1}"#
    }

    /// Answers the three calls of a run: the list URL, the PUT to storage and the start, the last with `start`.
    func collector(start: SyncStubURLProtocol.Reply, put: SyncStubURLProtocol.Reply = .json(200, "")) -> HTTPSyncTransport {
        let checksum = Data(SHA256.hash(data: Self.liveList)).base64EncodedString()
        return transport { request in
            guard Self.isAPI(request) else { return put }
            return request.url?.path.hasSuffix("live-list-url") == true ? .json(200, Self.liveListAnswer(checksum: checksum)) : start
        }
    }

    @Test func aRunAsksForAListURLUploadsTheListThenStarts() async throws {
        let transport = collector(start: .json(202, #"{"runId":"\#(Self.runID)","serverTime":1}"#))
        #expect(try await transport.startGarbageCollection(liveList: Self.liveList, epoch: 3, asOfSeq: 42) == .started)

        let seen = requests
        #expect(seen.count == 3)
        let ask = seen[0]
        #expect(ask.url?.path == "/api/v1/blobs/garbage-collection/live-list-url" && ask.httpMethod == "POST")
        #expect(ask.value(forHTTPHeaderField: "Authorization") == "Dev s3cret" && ask.value(forHTTPHeaderField: "x-tr-vault") == "v1")
        let checksum = Data(SHA256.hash(data: Self.liveList)).base64EncodedString()
        let expectedAsk: NSDictionary = ["epoch": 3, "size": 88, "sha256": checksum]
        #expect(try sentJSON(ask) == expectedAsk)

        let put = seen[1]
        #expect(put.url?.absoluteString == Self.listURL && put.httpMethod == "PUT")
        #expect(put.value(forHTTPHeaderField: "Authorization") == nil, "the dev secret never goes to storage")
        #expect(put.value(forHTTPHeaderField: "x-tr-vault") == nil)
        #expect(put.value(forHTTPHeaderField: "x-amz-checksum-sha256") == checksum)
        #expect(put.httpBody == Self.liveList)

        let start = seen[2]
        #expect(start.url?.path == "/api/v1/blobs/garbage-collection" && start.httpMethod == "POST")
        let expectedStart: NSDictionary = ["epoch": 3, "runId": Self.runID, "asOfSeq": 42]
        #expect(try sentJSON(start) == expectedStart)
    }

    @Test func anEmptyListIsSentLikeAnyOther() async throws {
        let transport = transport { request in
            guard Self.isAPI(request) else { return .json(200, "") }
            return request.url?.path.hasSuffix("live-list-url") == true ? .json(200, Self.liveListAnswer(checksum: "c")) : .json(202, #"{"runId":"\#(Self.runID)","serverTime":1}"#)
        }
        #expect(try await transport.startGarbageCollection(liveList: Data(), epoch: 1, asOfSeq: 0) == .started)
        let expected: NSDictionary = ["epoch": 1, "size": 0, "sha256": Data(SHA256.hash(data: Data())).base64EncodedString()]
        #expect(try sentJSON(requests[0]) == expected)
    }

    @Test func theServersRefusalsToStartAreAnswers() async throws {
        let stale = collector(start: .json(409, #"{"error":"garbage_collection_stale","headSeq":43,"serverTime":1}"#))
        #expect(try await stale.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42) == .stale)
        let missing = collector(start: .json(409, #"{"error":"live_list_missing","serverTime":1}"#))
        #expect(try await missing.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42) == .liveListMissing)
        let elsewhere = collector(start: .json(404, #"{"error":"live_list_missing","serverTime":1}"#))
        #expect(try await elsewhere.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42) == .liveListMissing, "by code, not status")
    }

    @Test func aRateLimitIsAnAnswerAndIsNotRetried() async throws {
        let transport = collector(start: .json(429, #"{"error":"garbage_collection_rate_limited","retryAfterSeconds":2400,"serverTime":1}"#))
        #expect(try await transport.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42) == .rateLimited(retryAfterSeconds: 2400))
        #expect(requests.count == 3, "the start was sent once")
    }

    @Test func aBusyServerIsRetriedThenUnavailable() async throws {
        let transport = collector(start: .json(503, #"{"error":"busy","message":"The vault is busy, try again","serverTime":1}"#))
        await #expect(throws: SyncTransportError.unavailable) {
            try await transport.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42)
        }
        #expect(requests.count == 2 + 3, "the list URL and the PUT once, the start up to maxAttempts times")
    }

    @Test func aStartTheServerRefusesOutrightIsRefusedForTheEngineToHandle() async throws {
        let transport = collector(start: .json(400, #"{"error":"bad_request","message":"Live list has the wrong size","serverTime":1}"#))
        await #expect(throws: SyncTransportError.refused(status: 400, message: "Live list has the wrong size")) {
            try await transport.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42)
        }
    }

    @Test func aStaleEpochIsAnEpochChange() async throws {
        let atListURL = transport { _ in .json(409, Self.epochChangedBody) }
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) {
            try await atListURL.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42)
        }
        let atStart = collector(start: .json(409, Self.epochChangedBody))
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) {
            try await atStart.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42)
        }
    }

    @Test func anExpiredListURLIsReplacedOnceThenRefused() async throws {
        let puts = OSAllocatedUnfairLock(initialState: 0)
        let checksum = Data(SHA256.hash(data: Self.liveList)).base64EncodedString()
        let recovering = transport { request in
            if Self.isAPI(request) {
                return request.url?.path.hasSuffix("live-list-url") == true ? .json(200, Self.liveListAnswer(checksum: checksum)) : .json(202, #"{"runId":"\#(Self.runID)","serverTime":1}"#)
            }
            return puts.withLock { $0 += 1; return $0 } == 1 ? .json(403, "<Error/>") : .json(200, "")
        }
        #expect(try await recovering.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42) == .started)
        #expect(requests.map { Self.isAPI($0) } == [true, false, true, false, true], "a fresh URL was asked for, then the start")

        let stuck = collector(start: .json(202, "{}"), put: .json(403, "<Error/>"))
        await #expect(throws: SyncTransportError.refused(status: 403, message: "Blob storage refused the request")) {
            try await stuck.startGarbageCollection(liveList: Self.liveList, epoch: 1, asOfSeq: 42)
        }
        #expect(requests.count == 4)
    }

    @Test func aFullVaultIsQuotaExceededNotTooLarge() async throws {
        let quota = transport { _ in .json(413, #"{"error":"quota_exceeded","usedBytes":10737000000,"limitBytes":10737418240,"serverTime":1}"#) }
        await #expect(throws: SyncTransportError.quotaExceeded(usedBytes: 10_737_000_000, limitBytes: 10_737_418_240)) {
            try await quota.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
        }
        #expect(requests.count == 1, "nothing was uploaded and the refusal is not retried")

        let tooLarge = transport { _ in .json(413, #"{"error":"too_large","message":"too big","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.tooLarge) { try await tooLarge.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1) }
    }
}
