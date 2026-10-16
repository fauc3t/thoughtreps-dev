import CryptoKit
import Foundation
import os

/// `SyncTransport` over the sync server's HTTP API (`SyncHTTPWireV1`).
///
/// Blobs go straight to S3 on presigned URLs the API hands out (`blobs/upload-urls`, `blobs/download-urls`). Those
/// requests are plain: they carry only the headers the signature covers, never the API's `Authorization` or `x-tr-vault`.
/// An expired URL (403) is replaced by a fresh one once; a 400, 411 or a second 403 means the request itself is wrong and
/// is refused.
///
/// A 5xx, 408, 429 or a failed connection is retried up to `maxAttempts` times with a growing pause (or the server's
/// `Retry-After`, at most `maxRetryAfter`). That is safe for a push
/// because the server checks every record's `baseSeq` again: a push that did commit before its answer was lost comes
/// back as a conflict, which the engine resolves by pulling.
struct HTTPSyncTransport: SyncTransport {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let maxRetryAfter: TimeInterval = 30

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    let baseURL: URL
    let vaultID: String
    private let devSecret: String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let offset: ServerClockOffset?
    private let maxAttempts: Int
    private let bestRoundTrip = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// `offset` is where the server-clock estimate is kept (nil: not tracked). `baseURL` ends in `/api/v1`.
    init(
        baseURL: URL, vaultID: String, devSecret: String, session: URLSession = HTTPSyncTransport.makeSession(),
        offset: ServerClockOffset? = nil, maxAttempts: Int = 3, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.baseURL = baseURL
        self.vaultID = vaultID
        self.devSecret = devSecret
        self.session = session
        self.offset = offset
        self.maxAttempts = maxAttempts
        self.now = now
        self.sleep = sleep
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    var supportsBlobs: Bool { true }

    // MARK: SyncTransport

    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult {
        let body = SyncHTTPWireV1.PushRequest(
            epoch: epoch, records: records.map { .init(key: $0.recordKey, baseSeq: $0.baseSeq, deleted: $0.deleted, payload: $0.payload) }
        )
        let response = try await send("push", method: "POST", body: try JSONEncoder().encode(body))
        switch response.status {
        case 200:
            let ok = try decode(SyncHTTPWireV1.PushOK.self, response)
            return .ok(seqs: ok.seqs, headSeq: ok.headSeq)
        case 409:
            let refusal = try decode(SyncHTTPWireV1.ErrorBody.self, response)
            if refusal.epochChanged == true || refusal.error == "epoch_changed", let epoch = refusal.epoch {
                throw SyncTransportError.epochChanged(server: epoch)
            }
            if refusal.error == "blob_missing" { return .blobsMissing(names: refusal.missingBlobs ?? []) }
            return .conflict(keys: refusal.conflicts ?? [])
        default:
            throw failure(response)
        }
    }

    func pull(after cursor: Int64, limit: Int) async throws -> PullPage {
        let query = [URLQueryItem(name: "since", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
        let response = try await send("pull", method: "GET", query: query)
        guard response.status == 200 else { throw failure(response) }
        let page = try decode(SyncHTTPWireV1.PullPage.self, response)
        return PullPage(
            records: page.records.map { PulledRecord(recordKey: $0.key, seq: $0.seq, payload: $0.payload, deleted: $0.deleted) },
            nextSeq: page.nextSeq, headSeq: page.headSeq, epoch: page.epoch, hasMore: page.more
        )
    }

    func head() async throws -> SyncHead {
        let response = try await send("head", method: "GET")
        guard response.status == 200 else { throw failure(response) }
        let head = try decode(SyncHTTPWireV1.Head.self, response)
        return SyncHead(headSeq: head.headSeq, epoch: head.epoch, liveRecordCount: head.liveRecordCount)
    }

    func hasBlob(name: String, epoch: Int64) async throws -> Bool {
        try await downloadURLs([name], epoch: epoch).downloads.contains { $0.name == name }
    }

    func putBlob(name: String, data: Data, epoch: Int64) async throws {
        let blob = SyncHTTPWireV1.BlobToUpload(name: name, size: data.count, sha256: Data(SHA256.hash(data: data)).base64EncodedString())
        var refreshed = false
        while true {
            let answer = try await blobAnswer(
                SyncHTTPWireV1.BlobUploadURLsResponse.self, "blobs/upload-urls", body: SyncHTTPWireV1.BlobUploadURLsRequest(epoch: epoch, blobs: [blob])
            )
            if answer.present.contains(name) { return }
            guard let upload = answer.uploads.first(where: { $0.name == name }), let url = URL(string: upload.url) else { throw SyncTransportError.unavailable }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            for (field, value) in upload.headers { request.setValue(value, forHTTPHeaderField: field) }
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            request.httpBody = data
            let response = try await perform(request, observesServerTime: false)
            switch response.status {
            case 200...299: return
            case 403 where !refreshed: refreshed = true
            default: throw storageFailure(response)
            }
        }
    }

    func getBlob(name: String, epoch: Int64, maxBytes: Int) async throws -> Data {
        var refreshed = false
        while true {
            let answer = try await downloadURLs([name], epoch: epoch)
            guard let download = answer.downloads.first(where: { $0.name == name }), let url = URL(string: download.url) else {
                throw answer.missing.contains(name) ? SyncTransportError.blobMissing(name) : SyncTransportError.unavailable
            }
            guard download.size <= maxBytes else { throw SyncTransportError.tooLarge }
            let response = try await fetch(URLRequest(url: url), maxBytes: maxBytes)
            switch response.status {
            case 200: return response.data
            case 403 where !refreshed: refreshed = true
            // A presigned GET for a deleted key answers 404 on our bucket (measured 2026-10-16), so a persistent 403 is a bug.
            case 404: throw SyncTransportError.blobMissing(name)
            default: throw storageFailure(response)
            }
        }
    }

    private func downloadURLs(_ names: [String], epoch: Int64) async throws -> SyncHTTPWireV1.BlobDownloadURLsResponse {
        try await blobAnswer(
            SyncHTTPWireV1.BlobDownloadURLsResponse.self, "blobs/download-urls", body: SyncHTTPWireV1.BlobDownloadURLsRequest(epoch: epoch, names: names)
        )
    }

    private func blobAnswer<Answer: Decodable>(_ type: Answer.Type, _ path: String, body: some Encodable) async throws -> Answer {
        let response = try await send(path, method: "POST", body: try JSONEncoder().encode(body))
        switch response.status {
        case 200:
            return try decode(type, response)
        case 409:
            let refusal = try decode(SyncHTTPWireV1.ErrorBody.self, response)
            if refusal.epochChanged == true || refusal.error == "epoch_changed", let epoch = refusal.epoch {
                throw SyncTransportError.epochChanged(server: epoch)
            }
            throw failure(response)
        default:
            throw failure(response)
        }
    }

    /// S3 answers a bad checksum or length (400, 411) or a signature that fails on a fresh URL (403) with a body that
    /// isn't ours. None of those can succeed on a retry.
    private func storageFailure(_ response: Response) -> SyncTransportError {
        guard [400, 403, 411].contains(response.status) else { return .unavailable }
        return .refused(status: response.status, message: "Blob storage refused the request")
    }

    // MARK: HTTP

    struct Response {
        var status: Int
        var data: Data
        var retryAfter: TimeInterval?

        var isTransient: Bool { status == 408 || status == 429 || (500...599).contains(status) }
    }

    func send(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw SyncTransportError.refused(status: 0, message: "bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        #if DEBUG
        request.setValue("Dev \(devSecret)", forHTTPHeaderField: "Authorization")
        #endif
        request.setValue(vaultID, forHTTPHeaderField: "x-tr-vault")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, observesServerTime: true)
    }

    /// `request` is sent as is. Only a call to our API reads `serverTime` off the answer.
    private func perform(_ request: URLRequest, observesServerTime: Bool) async throws -> Response {
        try await withRetries {
            let sentAt = now()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if observesServerTime { observeServerTime(data, sentAt: sentAt, receivedAt: now()) }
            return Response(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
    }

    /// A GET of a presigned URL, downloaded to a temp file (deleted afterwards). The body is read into memory only for a
    /// 200 whose announced and actual size are within `maxBytes`; otherwise `tooLarge`.
    private func fetch(_ request: URLRequest, maxBytes: Int) async throws -> Response {
        try await withRetries {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse else { return nil }
            var result = Response(status: http.statusCode, data: Data(), retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            guard http.statusCode == 200 else { return result }
            guard http.expectedContentLength <= maxBytes else { throw SyncTransportError.tooLarge }
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
            guard size <= maxBytes else { throw SyncTransportError.tooLarge }
            result.data = try Data(contentsOf: file, options: .mappedIfSafe)
            return result
        }
    }

    /// Runs `attempt` until it answers with something other than a transient status, at most `maxAttempts` times.
    private func withRetries(_ attempt: () async throws -> Response?) async throws -> Response {
        var attempts = 0
        while true {
            attempts += 1
            var result: Response?
            do {
                result = try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as SyncTransportError {
                throw error
            } catch {
                Self.logger.error("Sync request failed: \(error)")
            }
            if let result, !result.isTransient { return result }
            guard attempts < maxAttempts else { throw SyncTransportError.unavailable }
            let pause = result?.retryAfter.map { min(max($0, 0), Self.maxRetryAfter) } ?? Double(500 << (attempts - 1)) / 1000
            try await sleep(.seconds(pause))
        }
    }

    private func observeServerTime(_ data: Data, sentAt: Date, receivedAt: Date) {
        guard let offset, let serverTime = (try? JSONDecoder().decode(SyncHTTPWireV1.TimeOnly.self, from: data))?.serverTime else { return }
        let trip = receivedAt.timeIntervalSince(sentAt)
        let best = bestRoundTrip.withLock { best -> TimeInterval? in
            let previous = best
            if trip >= 0 { best = min(best ?? trip, trip) }
            return previous
        }
        if case .implausible(let seconds) = offset.observe(sentAt: sentAt, receivedAt: receivedAt, serverTimeMs: serverTime, bestRoundTrip: best) {
            Self.logger.error("Ignoring a server clock offset of \(seconds, format: .fixed(precision: 0)) s")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: Response) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            Self.logger.error("Undecodable sync response (\(response.status)): \(error)")
            throw SyncTransportError.unavailable
        }
    }

    /// The error for a status the call has no other meaning for: 413 is `tooLarge`; 400, 401, 403, 404 and 410 are the server
    /// saying this request will never work (a bad request, a refused secret, an unknown vault), which retrying can't fix.
    /// Anything else is treated as a failed call.
    private func failure(_ response: Response) -> SyncTransportError {
        if response.status == 413 { return .tooLarge }
        guard [400, 401, 403, 404, 410].contains(response.status) else { return .unavailable }
        let body = try? JSONDecoder().decode(SyncHTTPWireV1.ErrorBody.self, from: response.data)
        return .refused(status: response.status, message: body?.message ?? body?.error ?? "")
    }
}

#if DEBUG
extension HTTPSyncTransport {
    /// Creates the transport's vault (the dev route); the vault already existing is fine. Returns its epoch.
    @discardableResult
    func createVault() async throws -> Int64 {
        let body = try JSONEncoder().encode(SyncHTTPWireV1.CreateVaultRequest(vaultId: vaultID))
        let response = try await send("dev/vaults", method: "POST", body: body)
        guard response.status == 200 || response.status == 201 else { throw failure(response) }
        return try decode(SyncHTTPWireV1.CreateVault.self, response).epoch
    }

    /// Erases the vault (the dev route) and returns the epoch it moves to.
    @discardableResult
    func eraseVault() async throws -> Int64 {
        let response = try await send("dev/vaults/\(vaultID)/erase", method: "POST", body: Data("{}".utf8))
        guard response.status == 200 else { throw failure(response) }
        return try decode(SyncHTTPWireV1.EraseVault.self, response).epoch
    }
}
#endif
