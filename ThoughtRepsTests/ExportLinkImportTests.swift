import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

private let linkId = "AAAAAAAAAAAAAAAAAAAAAA"
private let keyText = String(repeating: "B", count: 43)
private let validLink = "https://transfer.thoughtreps.com/x/\(linkId)#\(keyText)"

@Suite("ParsedExportLink")
struct ParsedExportLinkTests {
    @Test func parsesTheGeneratedShape() {
        let key = ExportLinkCrypto.base64URL(ExportLinkCrypto.makeKey())
        let text = ExportLinkCrypto.link(exportLinkId: linkId, key: key)
        #expect(ParsedExportLink.parse(text) == ParsedExportLink(id: linkId, key: key))
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(ParsedExportLink.parse("  \n\(validLink) \t\n") == ParsedExportLink(id: linkId, key: keyText))
    }

    @Test(arguments: [
        "",
        "hello",
        "http://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://example.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB+",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAA=#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA?a=b#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA/#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB#C",
        "see https://transfer.thoughtreps.com/x/AAAAAAAAAAAAAAAAAAAAAA#BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    ])
    func rejects(_ text: String) {
        #expect(ParsedExportLink.parse(text) == nil)
    }

    @MainActor @Test func universalLinkURLsAreRecognized() {
        #expect(ExportLinkImportModel.handles(URL(string: validLink)!))
        #expect(!ExportLinkImportModel.handles(URL(string: "https://example.com/x/a")!))
        #expect(!ExportLinkImportModel.handles(URL(string: "thoughtreps://x")!))
    }
}

@Suite("ExportLinkCrypto decrypt")
struct ExportLinkDecryptTests {
    @Test func roundTrip() throws {
        let key = ExportLinkCrypto.makeKey()
        let plain = Data("a backup".utf8)
        #expect(try ExportLinkCrypto.decrypt(ExportLinkCrypto.encrypt(plain, key: key), key: key) == plain)
        #expect(try ExportLinkCrypto.decrypt(ExportLinkCrypto.encrypt(Data(), key: key), key: key) == Data())
    }

    @Test func keyFromLinkFragment() throws {
        let key = ExportLinkCrypto.makeKey()
        let parsed = try #require(ExportLinkCrypto.key(fromBase64URL: ExportLinkCrypto.base64URL(key)))
        #expect(parsed == key)
        #expect(ExportLinkCrypto.key(fromBase64URL: "short") == nil)
        #expect(ExportLinkCrypto.key(fromBase64URL: String(repeating: "!", count: 43)) == nil)
    }

    @Test func tamperedBytesFail() throws {
        let key = ExportLinkCrypto.makeKey()
        let file = try ExportLinkCrypto.encrypt(Data("a backup".utf8), key: key)
        for index in [4, 16, 20, file.count - 1] {
            var changed = file
            changed[index] ^= 0x01
            #expect(throws: ExportLinkCrypto.Failure.decryptionFailed) { try ExportLinkCrypto.decrypt(changed, key: key) }
        }
    }

    @Test func wrongKeyFails() throws {
        let file = try ExportLinkCrypto.encrypt(Data("x".utf8), key: ExportLinkCrypto.makeKey())
        #expect(throws: ExportLinkCrypto.Failure.decryptionFailed) { try ExportLinkCrypto.decrypt(file, key: ExportLinkCrypto.makeKey()) }
    }

    @Test func badMagicAndShortInputFail() throws {
        let key = ExportLinkCrypto.makeKey()
        var file = try ExportLinkCrypto.encrypt(Data("x".utf8), key: key)
        let truncated = file.prefix(ExportLinkCrypto.overheadBytes - 1)
        file[0] = 0x58
        #expect(throws: ExportLinkCrypto.Failure.badFormat) { try ExportLinkCrypto.decrypt(file, key: key) }
        #expect(throws: ExportLinkCrypto.Failure.badFormat) { try ExportLinkCrypto.decrypt(Data(truncated), key: key) }
        #expect(throws: ExportLinkCrypto.Failure.badFormat) { try ExportLinkCrypto.decrypt(Data(), key: key) }
    }
}

private final class FakeAPI: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    var replies: [String: (Int, String)]
    var error: Error?
    var onFirstRequest: (@Sendable () async -> Void)?

    init(_ replies: [String: (Int, String)] = [:]) { self.replies = replies }

    var requests: [String] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "?") \(request.url!.path)"
        lock.withLock { _requests.append(key) }
        if let hook = lock.withLock({ let hook = onFirstRequest; onFirstRequest = nil; return hook }) { await hook() }
        if let error { throw error }
        let (status, body) = replies[key] ?? (404, #"{"error":"not_found","message":"x"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class FakeDownloader: ExportDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _downloads = 0
    var body: Data?
    var onDownload: (@Sendable () async -> Void)?

    var downloads: Int { lock.withLock { _downloads } }

    func download(from url: URL, to destination: URL, progress report: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { _downloads += 1 }
        await onDownload?()
        guard let body else { throw ExportLinkImportError.downloadFailed }
        report(0.5)
        try body.write(to: destination)
    }
}

private struct Fixture {
    let key = ExportLinkCrypto.makeKey()
    let plain = Data("zip bytes".utf8)
    let api: FakeAPI
    let downloader = FakeDownloader()
    let encrypted: Data

    var link: ParsedExportLink { ParsedExportLink(id: linkId, key: ExportLinkCrypto.base64URL(key)) }
    var service: ExportLinkImportService {
        ExportLinkImportService(baseURL: URL(string: "https://example.test/api/v1")!, transport: api, downloader: downloader)
    }

    init(expiresAt: String = "2099-01-01T00:00:00Z") throws {
        encrypted = try ExportLinkCrypto.encrypt(plain, key: key)
        let claim = """
        {"download":{"url":"https://s3.test/object","expiresAt":"\(expiresAt)"},"sizeBytes":\(encrypted.count),"sha256":"\(ExportLinkCrypto.sha256Base64(encrypted))"}
        """
        api = FakeAPI([
            "GET /api/v1/export-links/\(linkId)": (200, #"{"status":"ready","sizeBytes":2048,"expiresAt":"2099-01-01T00:00:00.000Z"}"#),
            "POST /api/v1/export-links/\(linkId)/claim": (200, claim),
            "POST /api/v1/export-links/\(linkId)/done": (204, ""),
        ])
        downloader.body = encrypted
    }
}

@Suite("ExportLinkImportService")
struct ExportLinkImportServiceTests {
    @Test func statusReady() async throws {
        let fixture = try Fixture()
        let status = try await fixture.service.status(id: linkId)
        #expect(status == .ready(sizeBytes: 2048, expiresAt: Date(timeIntervalSince1970: 4_070_908_800)))
        #expect(fixture.api.requests == ["GET /api/v1/export-links/\(linkId)"])
    }

    @Test(arguments: [
        ("used", ExportLinkStatus.used), ("expired", .expired), ("revoked", .revoked),
    ])
    func statusUnavailable(_ name: String, _ expected: ExportLinkStatus) async throws {
        let fixture = try Fixture()
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (200, #"{"status":"\#(name)"}"#)
        #expect(try await fixture.service.status(id: linkId) == expected)
    }

    @Test func statusErrors() async throws {
        let fixture = try Fixture()
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (404, #"{"error":"not_found","message":"x"}"#)
        await #expect(throws: ExportLinkImportError.notFound) { try await fixture.service.status(id: linkId) }
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (500, #"{"message":"boom"}"#)
        await #expect(throws: ExportLinkImportError.network) { try await fixture.service.status(id: linkId) }
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (200, "not json")
        await #expect(throws: ExportLinkImportError.network) { try await fixture.service.status(id: linkId) }
        fixture.api.error = URLError(.notConnectedToInternet)
        await #expect(throws: ExportLinkImportError.network) { try await fixture.service.status(id: linkId) }
    }

    @Test func claimDecodesAndMapsErrors() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        #expect(claim.sizeBytes == fixture.encrypted.count)
        #expect(claim.download.url.absoluteString == "https://s3.test/object")
        fixture.api.replies["POST /api/v1/export-links/\(linkId)/claim"] = (409, #"{"error":"used","message":"x"}"#)
        await #expect(throws: ExportLinkImportError.used) { try await fixture.service.claim(id: linkId) }
        fixture.api.replies["POST /api/v1/export-links/\(linkId)/claim"] = (410, #"{"error":"expired","message":"x"}"#)
        await #expect(throws: ExportLinkImportError.expired) { try await fixture.service.claim(id: linkId) }
    }

    @Test func retrieveDecryptsThenMarksDone() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        let file = try await fixture.service.retrieve(claim, link: fixture.link) { _ in }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: file) == fixture.plain)
        #expect(file.lastPathComponent == "import.thoughtreps")
        #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix(BackupFormat.importDirectoryPrefix))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("download.bin").path))
        #expect(fixture.api.requests.last == "POST /api/v1/export-links/\(linkId)/done")
    }

    @Test func hashMismatchIsDamagedAndNotDone() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        var tampered = fixture.encrypted
        tampered[tampered.count - 1] ^= 0x01
        fixture.downloader.body = tampered
        await #expect(throws: ExportLinkImportError.damaged) {
            try await fixture.service.retrieve(claim, link: fixture.link) { _ in }
        }
        #expect(!fixture.api.requests.contains { $0.hasSuffix("/done") })
    }

    @Test func wrongKeyIsDamaged() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        let other = ParsedExportLink(id: linkId, key: ExportLinkCrypto.base64URL(ExportLinkCrypto.makeKey()))
        await #expect(throws: ExportLinkImportError.damaged) {
            try await fixture.service.retrieve(claim, link: other) { _ in }
        }
        #expect(!fixture.api.requests.contains { $0.hasSuffix("/done") })
    }

    @Test func downloadFailureAndWrongSizeAreRetryableAndNotDone() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        fixture.downloader.body = nil
        await #expect(throws: ExportLinkImportError.downloadFailed) {
            try await fixture.service.retrieve(claim, link: fixture.link) { _ in }
        }
        fixture.downloader.body = fixture.encrypted.dropLast()
        await #expect(throws: ExportLinkImportError.downloadFailed) {
            try await fixture.service.retrieve(claim, link: fixture.link) { _ in }
        }
        #expect(!fixture.api.requests.contains { $0.hasSuffix("/done") })
    }

    @Test func failedRetrieveLeavesNoTemporaryDirectory() async throws {
        let fixture = try Fixture()
        let claim = try await fixture.service.claim(id: linkId)
        fixture.downloader.body = nil
        let before = importDirectories()
        _ = try? await fixture.service.retrieve(claim, link: fixture.link) { _ in }
        #expect(importDirectories().subtracting(before).isEmpty)
    }
}

@MainActor
@Suite("ExportLinkImportModel")
struct ExportLinkImportModelTests {
    private func make(_ fixture: Fixture) -> (ExportLinkImportModel, BackupModel) {
        let backup = BackupModel()
        let model = ExportLinkImportModel(service: fixture.service, backup: backup, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (model, backup)
    }

    @Test func invalidTextShowsMessageWithoutNetwork() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        model.text = "nonsense"
        await model.checkStatus()
        #expect(model.message == "This doesn't look like a Thought Reps export link.")
        #expect(model.phase == .entry)
        #expect(fixture.api.requests.isEmpty)
    }

    @Test func readyShowsSummaryAndNeverClaims() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        await model.present(opening: URL(string: "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)")!)
        #expect(model.isPresented)
        #expect(model.phase == .ready(sizeBytes: 2048, expiresAt: Date(timeIntervalSince1970: 4_070_908_800)))
        #expect(fixture.api.requests == ["GET /api/v1/export-links/\(linkId)"])
    }

    @Test(arguments: [
        ("used", "This link was already used."),
        ("expired", "This link has expired."),
        ("revoked", "This link was turned off."),
    ])
    func unavailableMessages(_ status: String, _ message: String) async throws {
        let fixture = try Fixture()
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (200, #"{"status":"\#(status)"}"#)
        let (model, _) = make(fixture)
        model.text = validLink.replacingOccurrences(of: keyText, with: fixture.link.key)
        await model.checkStatus()
        #expect(model.message == message)
        #expect(model.phase == .entry)
    }

    @Test func notFoundAndNetworkMessages() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        model.text = validLink
        fixture.api.replies["GET /api/v1/export-links/\(linkId)"] = (404, #"{"error":"not_found","message":"x"}"#)
        await model.checkStatus()
        #expect(model.message == "We couldn't find this link.")
        fixture.api.error = URLError(.notConnectedToInternet)
        await model.checkStatus()
        #expect(model.message == "Couldn't reach Thought Reps. Check your connection and try again.")
    }

    @Test func importClaimsOnceAndHandsOffToTheReviewFlow() async throws {
        let fixture = try Fixture()
        let (model, backup) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        await model.startImport(container: container)
        #expect(fixture.api.requests.filter { $0.hasSuffix("/claim") }.count == 1)
        #expect(fixture.api.requests.last == "POST /api/v1/export-links/\(linkId)/done")
        #expect(backup.isPresentingImport)
        #expect(!model.isPresented)
        try await Task.sleep(for: .milliseconds(300))
        backup.dismissImport()
    }

    @Test func failedDownloadRetriesWithoutReclaiming() async throws {
        let fixture = try Fixture()
        let (model, backup) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        fixture.downloader.body = nil
        await model.startImport(container: container)
        #expect(model.phase == .retry)
        fixture.downloader.body = fixture.encrypted
        await model.retryDownload(container: container)
        #expect(fixture.api.requests.filter { $0.hasSuffix("/claim") }.count == 1)
        #expect(fixture.downloader.downloads == 2)
        #expect(backup.isPresentingImport)
        try await Task.sleep(for: .milliseconds(300))
        backup.dismissImport()
    }

    @Test func failedDownloadAfterUrlExpiryCannotRetry() async throws {
        let fixture = try Fixture(expiresAt: "2001-01-01T00:00:00Z")
        let (model, _) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        fixture.downloader.body = nil
        await model.startImport(container: container)
        #expect(model.phase == .entry)
        #expect(model.message?.contains("used up") == true)
    }

    @Test func damagedFileMessage() async throws {
        let fixture = try Fixture()
        let (model, backup) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        var tampered = fixture.encrypted
        tampered[tampered.count - 1] ^= 0x01
        fixture.downloader.body = tampered
        await model.startImport(container: container)
        #expect(model.message == "The downloaded file was damaged.")
        #expect(model.phase == .retry)
        #expect(!backup.isPresentingImport)
        fixture.downloader.body = fixture.encrypted
        await model.retryDownload(container: container)
        #expect(fixture.api.requests.filter { $0.hasSuffix("/claim") }.count == 1)
        #expect(backup.isPresentingImport)
        try await Task.sleep(for: .milliseconds(300))
        backup.dismissImport()
    }

    @Test func claimNetworkFailureKeepsTheLinkReady() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        fixture.api.replies["POST /api/v1/export-links/\(linkId)/claim"] = (500, #"{"message":"boom"}"#)
        await model.startImport(container: container)
        #expect(model.phase == .ready(sizeBytes: 2048, expiresAt: Date(timeIntervalSince1970: 4_070_908_800)))
        #expect(model.message == "Couldn't reach Thought Reps. Check your connection and try again.")
    }

    @Test func unreadableClaimReplyDoesNotOfferRetry() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        fixture.api.replies["POST /api/v1/export-links/\(linkId)/claim"] = (200, "garbage")
        await model.startImport(container: container)
        #expect(model.phase == .entry)
        #expect(model.message == "Something went wrong, and this link may be used up. Make a new link in Thought Reps on your other device.")
    }

    @Test func staleStatusResultReRunsForTheCurrentLink() async throws {
        let fixture = try Fixture()
        let (model, _) = make(fixture)
        let otherId = "CCCCCCCCCCCCCCCCCCCCCC"
        let other = "https://transfer.thoughtreps.com/x/\(otherId)#\(fixture.link.key)"
        fixture.api.replies["GET /api/v1/export-links/\(otherId)"] = (200, #"{"status":"used"}"#)
        fixture.api.onFirstRequest = { await MainActor.run { model.text = other } }
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        #expect(model.phase == .entry)
        #expect(!model.isWorking)
        #expect(model.message == "This link was already used.")
    }

    @Test func linkImportBlocksOtherImportsWhileClaimed() async throws {
        let fixture = try Fixture()
        let (model, backup) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        fixture.downloader.body = nil
        await model.startImport(container: container)
        #expect(model.phase == .retry)
        #expect(backup.isBusy)
        model.abandon()
        #expect(!backup.isBusy)
        #expect(!model.isPresented)
        #expect(model.phase == .entry)
    }

    @Test func busyAtHandoffRefusesAndCleansUp() async throws {
        let fixture = try Fixture()
        let (model, backup) = make(fixture)
        let container = try ModelContainer.thoughtReps(inMemory: true)
        fixture.downloader.onDownload = { await MainActor.run { backup.isSharingLink = true } }
        model.text = "https://transfer.thoughtreps.com/x/\(linkId)#\(fixture.link.key)"
        await model.checkStatus()
        await model.present()
        let before = importDirectories()
        await model.startImport(container: container)
        #expect(model.message == BackupModel.busyMessage)
        #expect(model.isPresented)
        #expect(!backup.isPresentingImport)
        #expect(importDirectories().subtracting(before).isEmpty)
    }
}

private func importDirectories() -> Set<String> {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
    return Set(contents.filter { $0.hasPrefix(BackupFormat.importDirectoryPrefix) })
}

@MainActor
@Suite("BackupModel link handoff")
struct BackupModelHandoffTests {
    @Test func consumingMovesTheFileAndRemovesItsFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(BackupFormat.importDirectoryPrefix)test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("import.thoughtreps")
        try Data("not a zip".utf8).write(to: file)
        let backup = BackupModel()
        #expect(backup.beginImport(from: file, container: try ModelContainer.thoughtReps(inMemory: true), consuming: true))
        for _ in 0..<100 where FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        backup.dismissImport()
    }

    @Test func busyRefusalReturnsFalseAndLeavesTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("busy-\(UUID().uuidString).thoughtreps")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let backup = BackupModel()
        backup.isImportingLink = true
        #expect(!backup.beginImport(from: file, container: try ModelContainer.thoughtReps(inMemory: true), consuming: true))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(backup.problem == BackupModel.busyMessage)
    }

    @Test func staleSweepRemovesLinkImportFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        let stale = root.appendingPathComponent("\(BackupFormat.importDirectoryPrefix)abc", isDirectory: true)
        let other = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        BackupModel().removeStaleTemporaryFiles(in: root)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
