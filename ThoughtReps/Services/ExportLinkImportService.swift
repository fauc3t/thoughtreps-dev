import CryptoKit
import Foundation

enum ExportLinkImportError: Error, Equatable {
    case notFound, used, expired, revoked
    /// Offline, a server error, or a reply we couldn't read: the link has not been used up.
    case network
    /// The download failed; the claim's URL may still allow another try.
    case downloadFailed
    /// The claim succeeded but its reply couldn't be read, so the link may be used up with nothing to download.
    case claimUnreadable
    /// The file failed the hash check, or didn't decrypt with this link's key.
    case damaged
}

enum ExportLinkStatus: Equatable, Sendable {
    case ready(sizeBytes: Int, expiresAt: Date)
    case used, expired, revoked
}

struct ExportLinkClaim: Decodable, Equatable, Sendable {
    struct Download: Decodable, Equatable, Sendable {
        let url: URL
        let expiresAt: Date

        private enum CodingKeys: String, CodingKey { case url, expiresAt }

        init(url: URL, expiresAt: Date) {
            self.url = url
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(URL.self, forKey: .url)
            expiresAt = try container.decodeISO8601(forKey: .expiresAt)
        }
    }

    let download: Download
    let sizeBytes: Int
    let sha256: String
}

protocol ExportDownloading: Sendable {
    /// Saves the body of a successful GET at `destination`, reporting the fraction received.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The presigned S3 GET: plain URLSession, no App Attest.
struct URLSessionDownloader: ExportDownloading {
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: ProgressDelegate(progress))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                throw ExportLinkImportError.downloadFailed
            }
            try FileManager.default.moveItem(at: file, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        } catch let error as URLError {
            throw error.code == .cancelled ? CancellationError() : ExportLinkImportError.downloadFailed
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Double) -> Void

        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

/// The public, unsigned `/export-links/{id}` endpoints, the presigned download, and the decryption.
/// The key never leaves the device.
struct ExportLinkImportService: Sendable {
    var baseURL: URL = AppAttestClient.productionBaseURL
    var transport: HTTPTransport = URLSessionTransport()
    var downloader: ExportDownloading = URLSessionDownloader()

    /// Doesn't use the link up.
    func status(id: String) async throws -> ExportLinkStatus {
        let data = try await send("GET", "export-links/\(id)")
        guard let body = try? JSONDecoder().decode(StatusBody.self, from: data) else { throw ExportLinkImportError.network }
        switch body.status {
        case "ready":
            guard let sizeBytes = body.sizeBytes, let expiresAt = body.expiresAt else { throw ExportLinkImportError.network }
            return .ready(sizeBytes: sizeBytes, expiresAt: expiresAt)
        case "used": return .used
        case "expired": return .expired
        case "revoked": return .revoked
        default: throw ExportLinkImportError.network
        }
    }

    /// Uses the link up: afterwards only the returned claim can fetch the file.
    func claim(id: String) async throws -> ExportLinkClaim {
        let data = try await send("POST", "export-links/\(id)/claim")
        guard let claim = try? JSONDecoder().decode(ExportLinkClaim.self, from: data) else { throw ExportLinkImportError.claimUnreadable }
        return claim
    }

    /// Downloads, checks the ciphertext hash, decrypts into a new `ThoughtRepsImport-` directory and
    /// returns the backup file there, then tells the server it is done. A failure removes the directory;
    /// `.downloadFailed` and `.damaged` are worth retrying with the same claim.
    func retrieve(
        _ claim: ExportLinkClaim,
        link: ParsedExportLink,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let key = ExportLinkCrypto.key(fromBase64URL: link.key) else { throw ExportLinkImportError.damaged }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(BackupFormat.importDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encrypted = directory.appendingPathComponent("download.bin")
        let backup = directory.appendingPathComponent("import.\(BackupFormat.fileExtension)")
        do {
            try await downloader.download(from: claim.download.url, to: encrypted, progress: progress)
            try verifyAndDecrypt(encrypted, to: backup, claim: claim, key: key)
            try? FileManager.default.removeItem(at: encrypted)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await markDone(id: link.id)
        return backup
    }

    private func verifyAndDecrypt(_ encrypted: URL, to backup: URL, claim: ExportLinkClaim, key: SymmetricKey) throws {
        let ciphertext: Data
        do {
            ciphertext = try Data(contentsOf: encrypted, options: .mappedIfSafe)
        } catch {
            throw ExportLinkImportError.downloadFailed
        }
        guard ciphertext.count == claim.sizeBytes else { throw ExportLinkImportError.downloadFailed }
        guard ExportLinkCrypto.sha256Base64(ciphertext) == claim.sha256 else { throw ExportLinkImportError.damaged }
        let plain: Data
        do {
            plain = try ExportLinkCrypto.decrypt(ciphertext, key: key)
        } catch {
            throw ExportLinkImportError.damaged
        }
        try plain.write(to: backup, options: .completeFileProtection)
    }

    /// Best effort: the server's sweep removes the object when this never arrives.
    func markDone(id: String) async {
        _ = try? await send("POST", "export-links/\(id)/done")
    }

    private func send(_ method: String, _ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportLinkImportError.network
        }
        guard (200..<300).contains(response.statusCode) else {
            switch APIError.from(status: response.statusCode, body: data) {
            case .notFound: throw ExportLinkImportError.notFound
            case .used: throw ExportLinkImportError.used
            case .expired: throw ExportLinkImportError.expired
            case .revoked: throw ExportLinkImportError.revoked
            default: throw ExportLinkImportError.network
            }
        }
        return data
    }

    private struct StatusBody: Decodable {
        let status: String
        let sizeBytes: Int?
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey { case status, sizeBytes, expiresAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
            expiresAt = container.contains(.expiresAt) ? try container.decodeISO8601(forKey: .expiresAt) : nil
        }
    }
}
