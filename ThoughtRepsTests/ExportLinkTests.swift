import CryptoKit
import Foundation
import Security
import SwiftData
import Testing
@testable import ThoughtReps

private func decodeBase64URL(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(BackupFormat.exportDirectoryPrefix)test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let linkId = "AAAAAAAAAAAAAAAAAAAAAA"
private let otherId = "BBBBBBBBBBBBBBBBBBBBBB"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("ExportLinkCrypto")
struct ExportLinkCryptoTests {
    @Test func layoutAndRoundTrip() throws {
        let key = ExportLinkCrypto.makeKey()
        let plain = Data("hello thought reps".utf8)
        let file = try ExportLinkCrypto.encrypt(plain, key: key)

        #expect(file.prefix(4) == Data("TRB1".utf8))
        #expect(file.count == 4 + 12 + plain.count + 16)
        let box = try AES.GCM.SealedBox(combined: file.dropFirst(4))
        #expect(try AES.GCM.open(box, using: key) == plain)
        #expect(try ExportLinkCrypto.encrypt(plain, key: key) != file)
    }

    @Test func wrongKeyFailsToOpen() throws {
        let file = try ExportLinkCrypto.encrypt(Data("x".utf8), key: ExportLinkCrypto.makeKey())
        let box = try AES.GCM.SealedBox(combined: file.dropFirst(4))
        #expect(throws: (any Error).self) { try AES.GCM.open(box, using: ExportLinkCrypto.makeKey()) }
    }

    @Test func keyIsBase64URLWithoutPadding() {
        for _ in 0..<50 {
            let key = ExportLinkCrypto.makeKey()
            let text = ExportLinkCrypto.base64URL(key)
            #expect(text.count == 43)
            #expect(text.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil)
            #expect(decodeBase64URL(text) == key.withUnsafeBytes { Data($0) })
        }
        let sample = SymmetricKey(data: Data(repeating: 0xFB, count: 32))
        #expect(ExportLinkCrypto.base64URL(sample).hasPrefix("-_v7"))
    }

    @Test func linkFormat() {
        #expect(ExportLinkCrypto.link(exportLinkId: linkId, key: "KEY") == "https://transfer.thoughtreps.com/x/\(linkId)#KEY")
    }

    @Test func sha256IsStandardBase64Of44Characters() {
        let hash = ExportLinkCrypto.sha256Base64(Data("abc".utf8))
        #expect(hash == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
        #expect(hash.count == 44)
    }

    @Test func sizeLimitIsOnTheEncryptedFile() throws {
        let limit = 100 * 1024 * 1024
        try ExportLinkCrypto.checkSize(plainBytes: limit - 32)
        #expect(throws: ExportLinkCrypto.Failure.tooLarge) { try ExportLinkCrypto.checkSize(plainBytes: limit - 31) }
    }

    @Test func oversizeFileIsRefusedBeforeReadingOrWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("big")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(100 * 1024 * 1024))
        try handle.close()
        let destination = directory.appendingPathComponent("out")

        #expect(throws: ExportLinkCrypto.Failure.tooLarge) {
            try ExportLinkCrypto.encryptFile(at: source, to: destination, key: ExportLinkCrypto.makeKey())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func encryptFileReportsSizeAndHashOfWhatItWrote() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plain")
        let destination = directory.appendingPathComponent("enc")
        try Data("zip bytes".utf8).write(to: source)

        let result = try ExportLinkCrypto.encryptFile(at: source, to: destination, key: ExportLinkCrypto.makeKey())
        let written = try Data(contentsOf: destination)
        #expect(result.sizeBytes == written.count)
        #expect(result.sha256 == ExportLinkCrypto.sha256Base64(written))
    }
}

@Suite("ExportLink decoding")
struct ExportLinkDecodingTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func createdWithReplacedLinkAndFractionalDate() throws {
        let created = try decode("""
        {"exportLinkId":"\(linkId)","replacedExportLinkId":"\(otherId)",
         "upload":{"method":"PUT","url":"https://s3.example/obj?sig=1","headers":{"x-amz-checksum-sha256":"abc","Content-Length":"9"},
                   "expiresAt":"2026-01-01T00:10:00.123Z"}}
        """, as: CreatedExportLink.self)
        #expect(created.replacedExportLinkId == otherId)
        #expect(created.upload.method == "PUT")
        #expect(created.upload.url.absoluteString == "https://s3.example/obj?sig=1")
        #expect(created.upload.headers == ["x-amz-checksum-sha256": "abc", "Content-Length": "9"])
        #expect(abs(created.upload.expiresAt.timeIntervalSince1970 - 1_767_226_200.123) < 0.001)
    }

    @Test(arguments: [#""replacedExportLinkId":null,"#, ""])
    func createdWithNoReplacedLink(field: String) throws {
        let created = try decode("""
        {"exportLinkId":"\(linkId)",\(field)
         "upload":{"method":"PUT","url":"https://s3.example/o","headers":{},"expiresAt":"2026-01-01T00:10:00Z"}}
        """, as: CreatedExportLink.self)
        #expect(created.replacedExportLinkId == nil)
        #expect(created.upload.expiresAt == Date(timeIntervalSince1970: 1_767_226_200))
    }

    @Test func summaryDecodesBothDateShapes() throws {
        let summary = try decode("""
        {"exportLinkId":"\(linkId)","status":"ready","sizeBytes":1234,
         "createdAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-02T00:00:00.500Z"}
        """, as: ExportLinkSummary.self)
        #expect(summary.status == .ready)
        #expect(summary.sizeBytes == 1234)
        #expect(summary.createdAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(summary.expiresAt == Date(timeIntervalSince1970: 1_767_312_000.5))
    }

    @Test func currentIsNullable() throws {
        #expect(try decode(#"{"exportLink":null}"#, as: ExportLinkService.CurrentResponse.self).exportLink == nil)
        let open = try decode("""
        {"exportLink":{"exportLinkId":"\(linkId)","status":"pending","sizeBytes":1,
                       "createdAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-01T00:10:00Z"}}
        """, as: ExportLinkService.CurrentResponse.self)
        #expect(open.exportLink?.status == .pending)
    }

    @Test func badDateAndStatusAreRejected() {
        let base = #"{"exportLinkId":"x","sizeBytes":1,"createdAt":"2026-01-01T00:00:00Z","#
        #expect(throws: (any Error).self) {
            try decode(base + #""status":"ready","expiresAt":"tomorrow"}"#, as: ExportLinkSummary.self)
        }
        #expect(throws: (any Error).self) {
            try decode(base + #""status":"used","expiresAt":"2026-01-01T00:00:00Z"}"#, as: ExportLinkSummary.self)
        }
    }

    @Test(arguments: [
        ("too_large", APIError.tooLarge), ("not_found", .notFound), ("upload_mismatch", .uploadMismatch),
        ("used", .used), ("expired", .expired), ("revoked", .revoked),
    ])
    func apiErrorMapping(code: String, expected: APIError) {
        let body = Data(#"{"error":"\#(code)","message":"x"}"#.utf8)
        #expect(APIError.from(status: 410, body: body) == expected)
    }

    @Test func linkIsGoneErrors() {
        for error in [APIError.notFound, .expired, .revoked, .used] { #expect(error.meansLinkIsGone) }
        for error in [APIError.offline, .tooLarge, .rateLimited, .server(status: 500)] { #expect(!error.meansLinkIsGone) }
    }
}

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func bodies(at path: String) -> [[String: Any]] {
        requests.filter { $0.url?.path == "/api/v1/\(path)" }.compactMap {
            $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct FakeAttest: AttestService {
    var isSupported = true
    func generateKey() async throws -> String { "key" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data() }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("a".utf8) }
}

private final class MemoryKeyIdStore: KeyIdStore, @unchecked Sendable {
    func load() throws -> String? { "key" }
    func save(_ keyId: String) throws {}
    func clear() {}
}

private final class RecordingUploader: ExportUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [(URL, ExportUploadTarget)] = []
    var uploads: [(URL, ExportUploadTarget)] { lock.withLock { _uploads } }
    var error: Error?
    var onUpload: (@Sendable (URL) -> Void)?
    func upload(file: URL, to target: ExportUploadTarget) async throws {
        onUpload?(file)
        if let error { throw error }
        lock.withLock { _uploads.append((file, target)) }
    }
}

private let challenge = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP-"

private func apiHandler(
    create: String? = nil, complete: String? = nil, current: String? = nil, revoke: String? = nil, status: Int = 200
) -> FakeTransport.Handler {
    { request in
        switch request.url?.path {
        case "/api/v1/challenge": (200, #"{"challenge":"\#(challenge)","expiresAt":"2026-01-01T00:00:00Z"}"#)
        case "/api/v1/export-links": (status, create ?? "{}")
        case "/api/v1/export-links/complete": (status, complete ?? "{}")
        case "/api/v1/export-links/current": (status, current ?? "{}")
        case "/api/v1/export-links/revoke": (status, revoke ?? "{}")
        default: (404, "")
        }
    }
}

private let createdJSON = """
{"exportLinkId":"\(linkId)","replacedExportLinkId":null,
 "upload":{"method":"PUT","url":"https://s3.example/obj","headers":{"x-amz-checksum-sha256":"abc"},"expiresAt":"2026-01-01T00:10:00.000Z"}}
"""
private func summaryJSON(id: String = linkId, expires: String = "2099-01-02T00:00:00.000Z") -> String {
    #"{"exportLinkId":"\#(id)","status":"ready","sizeBytes":100,"createdAt":"2026-01-01T00:00:00Z","expiresAt":"\#(expires)"}"#
}

private func service(_ transport: FakeTransport, uploader: RecordingUploader = RecordingUploader()) -> ExportLinkService {
    let client = AppAttestClient(
        baseURL: URL(string: "https://example.test/api/v1")!, transport: transport, attest: FakeAttest(), keyStore: MemoryKeyIdStore()
    )
    return ExportLinkService(client: client, uploader: uploader)
}

@Suite("ExportLinkService")
struct ExportLinkServiceTests {
    @Test func requestBodiesAndPaths() async throws {
        let transport = FakeTransport(apiHandler(
            create: createdJSON, complete: summaryJSON(), current: #"{"exportLink":null}"#, revoke: #"{"revoked":true}"#
        ))
        let service = service(transport)

        let created = try await service.create(sizeBytes: 77, sha256: "hash")
        #expect(created.exportLinkId == linkId)
        let summary = try await service.complete(exportLinkId: linkId)
        #expect(summary.status == .ready)
        #expect(try await service.current() == nil)
        try await service.revoke(exportLinkId: linkId)

        let create = try #require(transport.bodies(at: "export-links").first)
        #expect(create["challenge"] as? String == challenge)
        #expect(create["sizeBytes"] as? Int == 77)
        #expect(create["sha256"] as? String == "hash")
        #expect(transport.bodies(at: "export-links/complete").first?["exportLinkId"] as? String == linkId)
        #expect(transport.bodies(at: "export-links/current").first?.keys.sorted() == ["challenge"])
        #expect(transport.bodies(at: "export-links/revoke").first?["exportLinkId"] as? String == linkId)
    }

    @Test func serverCodesSurfaceAsTypedErrors() async {
        let transport = FakeTransport(apiHandler(complete: #"{"error":"expired","message":"x"}"#, status: 410))
        await #expect(throws: APIError.expired) { try await service(transport).complete(exportLinkId: linkId) }
    }

    @Test func unsupportedDeviceMakesNoRequest() async {
        let transport = FakeTransport(apiHandler())
        let client = AppAttestClient(
            baseURL: URL(string: "https://example.test/api/v1")!, transport: transport,
            attest: FakeAttest(isSupported: false), keyStore: MemoryKeyIdStore()
        )
        await #expect(throws: APIError.unsupported) {
            _ = try await ExportLinkService(client: client).create(sizeBytes: 1, sha256: "h")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func uploadGoesThroughTheUploader() async throws {
        let uploader = RecordingUploader()
        let target = ExportUploadTarget(method: "PUT", url: URL(string: "https://s3.example/o")!, headers: ["a": "b"], expiresAt: now)
        try await service(FakeTransport(apiHandler()), uploader: uploader).upload(file: URL(fileURLWithPath: "/tmp/f"), to: target)
        #expect(uploader.uploads.first?.1 == target)
    }
}

private final class MemoryLinkStore: ExportLinkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredExportLink?
    private(set) var clears = 0
    var saveFails = false
    init(_ value: StoredExportLink? = nil) { self.value = value }
    var stored: StoredExportLink? { lock.withLock { value } }
    func load() throws -> StoredExportLink? { stored }
    func save(_ link: StoredExportLink) throws {
        if saveFails { throw KeychainStatusError(status: -25308) }
        lock.withLock { value = link }
    }
    func clear() { lock.withLock { value = nil; clears += 1 } }
}

private final class FakeLinkService: ExportLinkServing, @unchecked Sendable {
    var createError: Error?
    var completeError: Error?
    var currentResult: Result<ExportLinkSummary?, Error> = .success(nil)
    var revokeError: Error?
    private(set) var calls: [String] = []
    private(set) var created: (Int, String)?
    private(set) var uploadedFile: URL?
    var onUpload: (@MainActor @Sendable () -> Void)?
    var onCreate: (@Sendable () async -> Void)?
    var onCurrent: (@Sendable () async -> Void)?
    var replacedId: String? = otherId

    func create(sizeBytes: Int, sha256: String) async throws -> CreatedExportLink {
        calls.append("create")
        await onCreate?()
        if let createError { throw createError }
        created = (sizeBytes, sha256)
        return CreatedExportLink(
            exportLinkId: linkId, replacedExportLinkId: replacedId,
            upload: ExportUploadTarget(method: "PUT", url: URL(string: "https://s3.example/o")!, headers: [:], expiresAt: now)
        )
    }
    func upload(file: URL, to target: ExportUploadTarget) async throws {
        calls.append("upload")
        uploadedFile = file
        await onUpload?()
    }
    func complete(exportLinkId: String) async throws -> ExportLinkSummary {
        calls.append("complete")
        if let completeError { throw completeError }
        return ExportLinkSummary(
            exportLinkId: exportLinkId, status: .ready, sizeBytes: 1, createdAt: now, expiresAt: now.addingTimeInterval(86_400)
        )
    }
    func current() async throws -> ExportLinkSummary? {
        calls.append("current")
        await onCurrent?()
        return try currentResult.get()
    }
    func revoke(exportLinkId: String) async throws {
        calls.append("revoke")
        if let revokeError { throw revokeError }
    }
}

private func summary(id: String) -> ExportLinkSummary {
    ExportLinkSummary(exportLinkId: id, status: .ready, sizeBytes: 1, createdAt: now, expiresAt: now.addingTimeInterval(3600))
}

private func archive() throws -> URL {
    let directory = try temporaryDirectory()
    let url = directory.appendingPathComponent("ThoughtReps.thoughtreps")
    try Data("zip".utf8).write(to: url)
    return url
}

@MainActor
private func makeModel(
    service: FakeLinkService = FakeLinkService(), store: MemoryLinkStore = MemoryLinkStore()
) -> (ExportLinkModel, BackupModel) {
    let backup = BackupModel()
    return (ExportLinkModel(backup: backup, service: service, store: store), backup)
}

@Suite("ExportLinkModel")
@MainActor
struct ExportLinkModelTests {
    private let old = StoredExportLink(exportLinkId: otherId, key: "oldkey", expiresAt: now.addingTimeInterval(3600))

    @Test func publishEncryptsUploadsStoresKeyAndCleansUp() async throws {
        let service = FakeLinkService()
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        let file = try archive()
        let directory = file.deletingLastPathComponent()
        let observed = LockedBox<Bool?>(nil)
        service.onUpload = { observed.set(FileManager.default.fileExists(atPath: directory.appendingPathComponent("export.encrypted").path)) }

        try await model.publish(archive: file)

        #expect(service.calls == ["create", "upload", "complete"])
        #expect(observed.value == true)
        #expect(service.created?.0 == 4 + 12 + 3 + 16)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let stored = try #require(store.stored)
        #expect(stored.exportLinkId == linkId)
        #expect(stored.key.count == 43)
        #expect(stored.expiresAt == now.addingTimeInterval(86_400))
        #expect(model.openLink == stored)
        #expect(stored.link == "https://transfer.thoughtreps.com/x/\(linkId)#\(stored.key)")
        #expect(model.stage == nil)
    }

    @Test func replacedLinkIsDroppedEvenIfUploadFails() async throws {
        let service = FakeLinkService()
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        service.completeError = APIError.offline
        let file = try archive()

        await #expect(throws: ExportLinkError.self) { try await model.publish(archive: file) }
        #expect(store.stored == nil)
        #expect(model.openLink == nil)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func failedCreateKeepsTheOldLinkAndCleansUp() async throws {
        let service = FakeLinkService()
        service.createError = APIError.rateLimited
        service.currentResult = .success(summary(id: otherId))
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        let file = try archive()

        await #expect(throws: APIError.rateLimited) { try await model.publish(archive: file) }
        #expect(store.stored == old)
        #expect(service.calls.contains("upload") == false)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func oversizeArchiveMakesNoNetworkCall() async throws {
        let service = FakeLinkService()
        let (model, _) = makeModel(service: service)
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("big.thoughtreps")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ExportLinkCrypto.maxEncryptedBytes))
        try handle.close()

        await #expect(throws: ExportLinkCrypto.Failure.tooLarge) { try await model.publish(archive: file) }
        #expect(service.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func refreshDropsExpiredLinkWithoutAskingTheServer() async {
        let service = FakeLinkService()
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        await model.refresh(now: old.expiresAt)
        #expect(store.stored == nil)
        #expect(model.openLink == nil)
        #expect(service.calls.isEmpty)
    }

    @Test func refreshWithNoStoredLinkMakesNoRequest() async {
        let service = FakeLinkService()
        let (model, _) = makeModel(service: service)
        await model.refresh(now: now)
        #expect(service.calls.isEmpty)
    }

    @Test func refreshKeepsLinkThatServerStillHasOpen() async {
        let service = FakeLinkService()
        service.currentResult = .success(summary(id: otherId))
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        #expect(store.stored == old)
        #expect(model.openLink == old)
    }

    @Test(arguments: [nil, summary(id: linkId)])
    func refreshDropsLinkServerNoLongerReports(current: ExportLinkSummary?) async {
        let service = FakeLinkService()
        service.currentResult = .success(current)
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        #expect(store.stored == nil)
        #expect(model.openLink == nil)
    }

    @Test func refreshNetworkFailureIsSilentAndKeepsLink() async {
        let service = FakeLinkService()
        service.currentResult = .failure(APIError.offline)
        let store = MemoryLinkStore(old)
        let (model, backup) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        #expect(store.stored == old)
        #expect(model.openLink == old)
        #expect(backup.problem == nil)
    }

    @Test func revokeClearsStoredKey() async {
        let service = FakeLinkService()
        service.currentResult = .success(summary(id: otherId))
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        await model.revoke()
        #expect(service.calls.last == "revoke")
        #expect(store.stored == nil)
        #expect(model.openLink == nil)
    }

    @Test func revokeOfAlreadyGoneLinkStillClears() async {
        let service = FakeLinkService()
        service.currentResult = .success(summary(id: otherId))
        service.revokeError = APIError.notFound
        let store = MemoryLinkStore(old)
        let (model, backup) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        await model.revoke()
        #expect(store.stored == nil)
        #expect(backup.problem == nil)
    }

    @Test func revokeFailureKeepsLinkAndReports() async {
        let service = FakeLinkService()
        service.currentResult = .success(summary(id: otherId))
        service.revokeError = APIError.offline
        let store = MemoryLinkStore(old)
        let (model, backup) = makeModel(service: service, store: store)
        await model.refresh(now: now)
        await model.revoke()
        #expect(store.stored == old)
        #expect(model.openLink == old)
        #expect(backup.problem == ExportLinkFailure(APIError.offline).message)
    }

    @Test func createRefusesWhileBackupIsBusy() async throws {
        let service = FakeLinkService()
        let (model, backup) = makeModel(service: service)
        backup.isSharingLink = true
        await model.create(from: try ModelContainer(for: Thought.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        #expect(backup.problem == "Wait for the current export or import to finish.")
        #expect(service.calls.isEmpty)
    }

    @Test func expiryText() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let today = Date(timeIntervalSince1970: 1_767_225_600 + 3600)
        #expect(ExportLinkModel.expiryText(today.addingTimeInterval(3600), now: today, calendar: calendar).hasPrefix("Expires today at"))
        #expect(ExportLinkModel.expiryText(today.addingTimeInterval(86_400), now: today, calendar: calendar).hasPrefix("Expires tomorrow at"))
        #expect(!ExportLinkModel.expiryText(today.addingTimeInterval(5 * 86_400), now: today, calendar: calendar).contains("today"))
    }

    @Test func failureMessages() {
        #expect(ExportLinkFailure(APIError.unsupported).message == "Export links need a real iPhone.")
        #expect(ExportLinkFailure(APIError.offline).message.contains("offline"))
        #expect(ExportLinkFailure(ExportLinkCrypto.Failure.tooLarge).message.contains("100 MB"))
        #expect(ExportLinkFailure(APIError.tooLarge).message.contains("100 MB"))
        #expect(ExportLinkFailure(APIError.revoked).message.contains("no longer available"))
        #expect(ExportLinkFailure(APIError.server(status: 500)).message.contains("couldn't be created"))
        #expect(ExportLinkFailure(APIError.server(status: 500), revoking: true).message.contains("revoked"))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

private actor Gate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { await Task.yield() }
}

@Suite("ExportLinkModel flows")
@MainActor
struct ExportLinkModelFlowTests {
    private let old = StoredExportLink(exportLinkId: otherId, key: "oldkey", expiresAt: Date.now.addingTimeInterval(3600))

    private func container() throws -> ModelContainer { try ModelContainer.thoughtReps(inMemory: true) }

    @Test func createEndToEndTogglesSharingAndLeavesNoTempFiles() async throws {
        let service = FakeLinkService()
        let (model, backup) = makeModel(service: service)
        let during = LockedBox<[Bool]>([])
        service.onUpload = { during.set([backup.isSharingLink, backup.isBusy, model.stage == .uploading]) }
        #expect(!backup.isSharingLink)

        await model.create(from: try container())

        #expect(during.value == [true, true, true])
        #expect(!backup.isSharingLink)
        #expect(model.stage == nil)
        #expect(backup.problem == nil)
        #expect(model.openLink?.exportLinkId == linkId)
        let uploaded = try #require(service.uploadedFile)
        #expect(!FileManager.default.fileExists(atPath: uploaded.deletingLastPathComponent().path))
    }

    @Test func createFailureReportsProblemAndResetsState() async throws {
        let service = FakeLinkService()
        service.createError = APIError.unsupported
        let (model, backup) = makeModel(service: service)
        await model.create(from: try container())
        #expect(backup.problem == "Export links need a real iPhone.")
        #expect(!backup.isSharingLink)
        #expect(model.stage == nil)
        #expect(model.openLink == nil)
    }

    @Test func failureAfterCreateSaysPreviousLinkWasReplaced() async throws {
        let service = FakeLinkService()
        service.completeError = APIError.offline
        let (model, backup) = makeModel(service: service, store: MemoryLinkStore(old))
        await model.create(from: try container())
        #expect(backup.problem?.hasPrefix("Your previous link was replaced and no longer works.") == true)
        #expect(backup.problem?.contains("offline") == true)
        #expect(!backup.isSharingLink)
    }

    @Test func failureAfterCreateWithoutPreviousLinkHasPlainMessage() async throws {
        let service = FakeLinkService()
        service.replacedId = nil
        service.completeError = APIError.offline
        let (model, backup) = makeModel(service: service)
        await model.create(from: try container())
        #expect(backup.problem == ExportLinkFailure(APIError.offline).message)
    }

    @Test func createIgnoredWhileWorking() async throws {
        let service = FakeLinkService()
        let gate = Gate()
        service.onCreate = { await gate.wait() }
        let (model, backup) = makeModel(service: service)
        let container = try container()
        let first = Task { await model.create(from: container) }
        await waitUntil { service.calls.contains("create") }
        await model.create(from: container)
        #expect(backup.problem == nil)
        #expect(service.calls.filter { $0 == "create" }.count == 1)
        await gate.open()
        await first.value
    }

    @Test func refreshDoesNotDropLinkWhilePublishing() async throws {
        let service = FakeLinkService()
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        let currentGate = Gate()
        let createGate = Gate()
        service.onCurrent = { await currentGate.wait() }
        service.onCreate = { await createGate.wait() }
        let refreshing = Task { await model.refresh(now: .now) }
        await waitUntil { service.calls.contains("current") }

        let file = try archive()
        let publishing = Task { try await model.publish(archive: file) }
        await waitUntil { service.calls.contains("create") }
        #expect(model.openLink == old)
        await currentGate.open()
        await refreshing.value
        #expect(model.openLink == old)
        #expect(store.stored == old)

        await createGate.open()
        try await publishing.value
    }

    @Test func refreshDoesNotDropANewerLink() async throws {
        let service = FakeLinkService()
        let store = MemoryLinkStore(old)
        let (model, _) = makeModel(service: service, store: store)
        let currentGate = Gate()
        service.onCurrent = { await currentGate.wait() }
        let refreshing = Task { await model.refresh(now: .now) }
        await waitUntil { service.calls.contains("current") }

        try await model.publish(archive: try archive())
        #expect(model.openLink?.exportLinkId == linkId)
        await currentGate.open()
        await refreshing.value
        #expect(store.stored?.exportLinkId == linkId)
        #expect(model.openLink?.exportLinkId == linkId)
    }
}

private final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) static var seen: [String: URLRequest] = [:]
    static let lock = NSLock()

    static func register(host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }
    static func request(host: String) -> URLRequest? { lock.withLock { seen[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.withLock { Self.seen[host] = request }
        guard let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite("URLSessionUploader")
struct URLSessionUploaderTests {
    private func uploader() -> URLSessionUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionUploader(session: URLSession(configuration: configuration))
    }

    private func target(host: String, headers: [String: String] = [:]) -> ExportUploadTarget {
        ExportUploadTarget(method: "PUT", url: URL(string: "https://\(host)/obj?sig=1")!, headers: headers, expiresAt: now)
    }

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: url)
        return url
    }

    @Test func sendsPutWithExactlyTheGivenHeaders() async throws {
        let host = "ok-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host) { _ in (200, Data()) }
        let source = try file()
        defer { try? FileManager.default.removeItem(at: source) }
        try await uploader().upload(file: source, to: target(host: host, headers: ["x-amz-checksum-sha256": "abc=", "Content-Type": "application/octet-stream"]))

        let request = try #require(StubURLProtocol.request(host: host))
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://\(host)/obj?sig=1")
        #expect(request.value(forHTTPHeaderField: "x-amz-checksum-sha256") == "abc=")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "x-tr-assertion") == nil)
    }

    @Test(arguments: [400, 403, 500])
    func nonSuccessStatusMapsToServerError(status: Int) async throws {
        let host = "fail-\(status)-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host) { _ in (status, Data("<Error/>".utf8)) }
        let source = try file()
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: APIError.server(status: status)) {
            try await uploader().upload(file: source, to: target(host: host))
        }
    }

    @Test func offlineAndOtherNetworkErrors() async throws {
        let offlineHost = "offline-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: offlineHost) { _ in throw URLError(.notConnectedToInternet) }
        let otherHost = "other-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: otherHost) { _ in throw URLError(.secureConnectionFailed) }
        let source = try file()
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: APIError.offline) { try await uploader().upload(file: source, to: target(host: offlineHost)) }
        await #expect(throws: APIError.network) { try await uploader().upload(file: source, to: target(host: otherHost)) }
    }

    @Test func cancellationIsNotAnAPIError() async throws {
        let host = "cancel-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host) { _ in throw URLError(.cancelled) }
        let source = try file()
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: CancellationError.self) { try await uploader().upload(file: source, to: target(host: host)) }
    }
}

@Suite("KeychainExportLinkStore", .serialized)
struct KeychainExportLinkStoreTests {
    private let stored = StoredExportLink(exportLinkId: linkId, key: "k", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    private let itemQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.thoughtreps.exportlink",
        kSecAttrAccount as String: "current",
    ]

    @Test func roundTripAndClear() throws {
        let store = KeychainExportLinkStore()
        store.clear()
        defer { store.clear() }
        #expect(try store.load() == nil)
        try store.save(stored)
        #expect(try store.load() == stored)
        let replacement = StoredExportLink(exportLinkId: otherId, key: "k2", expiresAt: stored.expiresAt)
        try store.save(replacement)
        #expect(try store.load() == replacement)
        store.clear()
        #expect(try store.load() == nil)
    }

    @Test func corruptItemIsDeletedAndReadsAsNil() throws {
        let store = KeychainExportLinkStore()
        store.clear()
        defer { store.clear() }
        let add = itemQuery.merging([kSecValueData as String: Data("not json".utf8)]) { $1 }
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(try store.load() == nil)
        #expect(SecItemCopyMatching(itemQuery as CFDictionary, nil) == errSecItemNotFound)
    }
}
