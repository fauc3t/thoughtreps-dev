import CryptoKit
import Foundation
import Testing
import os
@testable import ThoughtReps

/// The blob half of `HTTPSyncTransport`, in the same suite as the rest because the stub protocol's handler is shared.
extension HTTPSyncTransportTests {
    static let blobName = String(repeating: "A", count: 43)
    static let storageURL = "https://blobs.example.test/v/v1/e/1/b/\(blobName)?X-Amz-Signature=abc"

    static func isAPI(_ request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }

    static func uploadAnswer(checksum: String) -> String {
        #"{"uploads":[{"name":"\#(blobName)","url":"\#(storageURL)","headers":{"x-amz-checksum-sha256":"\#(checksum)"}}],"present":[],"serverTime":1}"#
    }

    static let downloadAnswer = #"{"downloads":[{"name":"\#(blobName)","url":"\#(storageURL)","size":11}],"missing":[],"serverTime":1}"#
    static let missingAnswer = #"{"downloads":[],"missing":["\#(blobName)"],"serverTime":1}"#
    static let epochChangedBody = #"{"error":"epoch_changed","epochChanged":true,"epoch":4,"serverTime":1}"#

    func sentJSON(_ request: URLRequest) throws -> NSDictionary {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    @Test func blobCallsAreSupported() async throws {
        #expect(transport { _ in .json(200, "{}") }.supportsBlobs)
    }

    @Test func anUploadSendsTheBytesToStorageWithOnlyTheSignedHeaders() async throws {
        let data = Data("sealed blob".utf8)
        let checksum = Data(SHA256.hash(data: data)).base64EncodedString()
        let transport = transport { request in
            Self.isAPI(request) ? .json(200, Self.uploadAnswer(checksum: checksum)) : .json(200, "")
        }
        try await transport.putBlob(name: Self.blobName, data: data, epoch: 1)

        let seen = requests
        #expect(seen.count == 2)
        let ask = try #require(seen.first)
        #expect(ask.url?.path == "/api/v1/blobs/upload-urls" && ask.httpMethod == "POST")
        #expect(ask.value(forHTTPHeaderField: "Authorization") == "Dev s3cret" && ask.value(forHTTPHeaderField: "x-tr-vault") == "v1")
        let expected: NSDictionary = ["epoch": 1, "blobs": [["name": Self.blobName, "size": data.count, "sha256": checksum]]]
        #expect(try sentJSON(ask) == expected)

        let put = try #require(seen.last)
        #expect(put.url?.absoluteString == Self.storageURL && put.httpMethod == "PUT")
        #expect(put.value(forHTTPHeaderField: "Authorization") == nil, "the dev secret never goes to storage")
        #expect(put.value(forHTTPHeaderField: "x-tr-vault") == nil)
        #expect(put.value(forHTTPHeaderField: "x-amz-checksum-sha256") == checksum)
        if let length = put.value(forHTTPHeaderField: "Content-Length") { #expect(length == String(data.count)) }
        #expect(put.httpBody?.count == data.count && put.httpBody == data, "the body sent is exactly the size announced")
    }

    @Test func aBlobTheServerAlreadyHasIsNotUploaded() async throws {
        let transport = transport { _ in .json(200, #"{"uploads":[],"present":["\#(Self.blobName)"],"serverTime":1}"#) }
        try await transport.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
        #expect(requests.count == 1)
    }

    @Test func anExpiredUploadURLIsReplacedOnceThenRefused() async throws {
        let puts = OSAllocatedUnfairLock(initialState: 0)
        let recovering = transport { request in
            guard !Self.isAPI(request) else { return .json(200, Self.uploadAnswer(checksum: "c")) }
            return puts.withLock { $0 += 1; return $0 } == 1 ? .json(403, "<Error><Code>AccessDenied</Code></Error>") : .json(200, "")
        }
        try await recovering.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
        #expect(requests.map { Self.isAPI($0) } == [true, false, true, false], "a fresh URL was asked for and used")

        let stuck = transport { request in Self.isAPI(request) ? .json(200, Self.uploadAnswer(checksum: "c")) : .json(403, "<Error/>") }
        await #expect(throws: SyncTransportError.refused(status: 403, message: "Blob storage refused the request")) {
            try await stuck.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
        }
        #expect(requests.count == 4, "only one fresh URL is tried")
    }

    @Test func aBadDigestOrMissingLengthIsRefusedNotRetried() async throws {
        for status in [400, 411] {
            let transport = transport { request in Self.isAPI(request) ? .json(200, Self.uploadAnswer(checksum: "c")) : .json(status, "<Error/>") }
            await #expect(throws: SyncTransportError.refused(status: status, message: "Blob storage refused the request")) {
                try await transport.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
            }
            #expect(requests.count == 2, "\(status) is not retried")
        }
    }

    @Test func aStorageOutageIsRetriedLikeAnyOtherCall() async throws {
        let transport = transport { request in Self.isAPI(request) ? .json(200, Self.uploadAnswer(checksum: "c")) : .json(503, "<Error/>") }
        await #expect(throws: SyncTransportError.unavailable) {
            try await transport.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1)
        }
        #expect(requests.count == 1 + 3, "one URL request, then the PUT up to maxAttempts times")
    }

    @Test func aStaleEpochOnAnyBlobCallIsAnEpochChange() async throws {
        let transport = transport { _ in .json(409, Self.epochChangedBody) }
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) { try await transport.putBlob(name: Self.blobName, data: Data("x".utf8), epoch: 1) }
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) { try await transport.hasBlob(name: Self.blobName, epoch: 1) }
        await #expect(throws: SyncTransportError.epochChanged(server: 4)) { try await transport.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100) }
    }

    @Test func hasBlobAsksForDownloadURLs() async throws {
        let present = transport { _ in .json(200, Self.downloadAnswer) }
        #expect(try await present.hasBlob(name: Self.blobName, epoch: 2))
        let ask = try #require(requests.first)
        #expect(ask.url?.path == "/api/v1/blobs/download-urls")
        let expected: NSDictionary = ["epoch": 2, "names": [Self.blobName]]
        #expect(try sentJSON(ask) == expected)
        let absent = transport { _ in .json(200, Self.missingAnswer) }
        #expect(try await !absent.hasBlob(name: Self.blobName, epoch: 2))
    }

    @Test func aDownloadFetchesFromStorageWithOnlyThePlainRequest() async throws {
        let data = Data("sealed blob".utf8)
        let transport = transport { request in
            Self.isAPI(request) ? .json(200, Self.downloadAnswer) : SyncStubURLProtocol.Reply(status: 200, body: "sealed blob", failure: nil, headers: ["Content-Length": "11"])
        }
        #expect(try await transport.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100) == data)
        let get = try #require(requests.last)
        #expect(get.url?.absoluteString == Self.storageURL && get.httpMethod == "GET")
        #expect(get.value(forHTTPHeaderField: "Authorization") == nil && get.value(forHTTPHeaderField: "x-tr-vault") == nil)
    }

    @Test func aMissingBlobIsBlobMissing() async throws {
        let listed = transport { _ in .json(200, Self.missingAnswer) }
        await #expect(throws: SyncTransportError.blobMissing(Self.blobName)) { try await listed.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100) }
        let deleted = transport { request in Self.isAPI(request) ? .json(200, Self.downloadAnswer) : .json(404, "<Error><Code>NoSuchKey</Code></Error>") }
        await #expect(throws: SyncTransportError.blobMissing(Self.blobName)) { try await deleted.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100) }
    }

    @Test func aBlobPastTheLimitIsRefusedBeforeAndWhileReading() async throws {
        let listedTooBig = transport { _ in .json(200, Self.downloadAnswer) }
        await #expect(throws: SyncTransportError.tooLarge) { try await listedTooBig.getBlob(name: Self.blobName, epoch: 1, maxBytes: 10) }
        #expect(requests.count == 1, "the size in the listing is enough: nothing is downloaded")

        let liar = transport { request in
            Self.isAPI(request) ? .json(200, Self.downloadAnswer) : .json(200, String(repeating: "x", count: 50))
        }
        await #expect(throws: SyncTransportError.tooLarge) { try await liar.getBlob(name: Self.blobName, epoch: 1, maxBytes: 20) }
        #expect(requests.count == 2, "the body was downloaded, then its size checked")
    }

    @Test func aDownloadThatKeepsGettingForbiddenIsRefused() async throws {
        let transport = transport { request in Self.isAPI(request) ? .json(200, Self.downloadAnswer) : .json(403, "<Error/>") }
        await #expect(throws: SyncTransportError.refused(status: 403, message: "Blob storage refused the request")) {
            try await transport.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100)
        }
        #expect(requests.count == 4, "one fresh URL, then refused")
    }

    @Test func anExpiredDownloadURLIsReplacedOnce() async throws {
        let gets = OSAllocatedUnfairLock(initialState: 0)
        let transport = transport { request in
            guard !Self.isAPI(request) else { return .json(200, Self.downloadAnswer) }
            return gets.withLock { $0 += 1; return $0 } == 1 ? .json(403, "<Error/>") : .json(200, "sealed blob")
        }
        #expect(try await transport.getBlob(name: Self.blobName, epoch: 1, maxBytes: 100) == Data("sealed blob".utf8))
        #expect(requests.map { Self.isAPI($0) } == [true, false, true, false])
    }

    @Test func aPushWhoseBlobIsMissingNamesIt() async throws {
        let transport = transport { _ in .json(409, #"{"error":"blob_missing","missingBlobs":["\#(Self.blobName)"],"serverTime":1}"#) }
        let pointer = PushRecord(recordKey: "a", baseSeq: nil, payload: SyncCrypto.pointer(toBlob: Self.blobName), deleted: false)
        #expect(try await transport.push([pointer], epoch: 1) == .blobsMissing(names: [Self.blobName]))
    }
}
