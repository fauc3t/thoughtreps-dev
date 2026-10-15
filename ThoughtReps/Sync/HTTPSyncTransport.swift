import Foundation
import os

/// `SyncTransport` over the sync server's HTTP API (`SyncHTTPWireV1`). The server has no blob routes until phase 3, so
/// the blob calls throw `unsupported` and the engine holds back what needs them (`supportsBlobs`).
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

    var supportsBlobs: Bool { false }

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
            return .conflict(keys: refusal.conflicts ?? [])
        default:
            throw failure(response)
        }
    }

    func pull(after cursor: Int64, limit: Int, fullResync: Bool) async throws -> PullResult {
        let query = [
            URLQueryItem(name: "since", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fullResync", value: fullResync ? "true" : "false"),
        ]
        let response = try await send("pull", method: "GET", query: query)
        switch response.status {
        case 200:
            let page = try decode(SyncHTTPWireV1.PullPage.self, response)
            return .page(PullPage(
                records: page.records.map { PulledRecord(recordKey: $0.key, seq: $0.seq, payload: $0.payload, deleted: $0.deleted) },
                nextSeq: page.nextSeq, headSeq: page.headSeq, epoch: page.epoch, hasMore: page.more
            ))
        case 410:
            return .gone
        default:
            throw failure(response)
        }
    }

    func head() async throws -> SyncHead {
        let response = try await send("head", method: "GET")
        guard response.status == 200 else { throw failure(response) }
        let head = try decode(SyncHTTPWireV1.Head.self, response)
        return SyncHead(headSeq: head.headSeq, epoch: head.epoch, liveRecordCount: head.liveRecordCount)
    }

    func putBlob(name: String, data: Data, epoch: Int64) async throws { throw SyncTransportError.unsupported }
    func getBlob(name: String, maxBytes: Int) async throws -> Data { throw SyncTransportError.unsupported }
    func hasBlob(name: String, epoch: Int64) async throws -> Bool { throw SyncTransportError.unsupported }

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
        var attempt = 0
        while true {
            attempt += 1
            let sentAt = now()
            var result: Response?
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    observeServerTime(data, sentAt: sentAt, receivedAt: now())
                    result = Response(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                Self.logger.error("Sync request failed: \(error)")
            }
            if let result, !result.isTransient { return result }
            guard attempt < maxAttempts else { throw SyncTransportError.unavailable }
            let pause = result?.retryAfter.map { min(max($0, 0), Self.maxRetryAfter) } ?? Double(500 << (attempt - 1)) / 1000
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

    /// The error for a status the call has no other meaning for: 413 is `tooLarge`; 400, 401, 403 and 404 are the server
    /// saying this request will never work (a bad request, a refused secret, an unknown vault), which retrying can't fix.
    /// Anything else is treated as a failed call.
    private func failure(_ response: Response) -> SyncTransportError {
        if response.status == 413 { return .tooLarge }
        guard [400, 401, 403, 404].contains(response.status) else { return .unavailable }
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
