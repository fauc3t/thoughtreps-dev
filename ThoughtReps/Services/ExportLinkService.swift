import Foundation
import os
import Security

struct ExportLinkSummary: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case pending
        case ready
    }

    let exportLinkId: String
    let status: Status
    let sizeBytes: Int
    let createdAt: Date
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case exportLinkId, status, sizeBytes, createdAt, expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exportLinkId = try container.decode(String.self, forKey: .exportLinkId)
        status = try container.decode(Status.self, forKey: .status)
        sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        createdAt = try container.decodeISO8601(forKey: .createdAt)
        expiresAt = try container.decodeISO8601(forKey: .expiresAt)
    }

    init(exportLinkId: String, status: Status, sizeBytes: Int, createdAt: Date, expiresAt: Date) {
        self.exportLinkId = exportLinkId
        self.status = status
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

struct ExportUploadTarget: Decodable, Equatable, Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case method, url, headers, expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(URL.self, forKey: .url)
        headers = try container.decode([String: String].self, forKey: .headers)
        expiresAt = try container.decodeISO8601(forKey: .expiresAt)
    }

    init(method: String, url: URL, headers: [String: String], expiresAt: Date) {
        self.method = method
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

struct CreatedExportLink: Decodable, Equatable, Sendable {
    let exportLinkId: String
    let replacedExportLinkId: String?
    let upload: ExportUploadTarget
}

private extension KeyedDecodingContainer {
    /// The server's ISO 8601 timestamps carry fractional seconds only sometimes.
    func decodeISO8601(forKey key: Key) throws -> Date {
        let text = try decode(String.self, forKey: key)
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an ISO 8601 date: \(text)")
    }
}

extension APIError {
    /// The server no longer has this link open, so a stored key for it is useless.
    var meansLinkIsGone: Bool {
        switch self {
        case .notFound, .expired, .revoked, .used: true
        default: false
        }
    }
}

protocol ExportUploading: Sendable {
    func upload(file: URL, to target: ExportUploadTarget) async throws
}

/// The presigned S3 PUT: plain URLSession with exactly the headers the server signed, not App Attest signed.
struct URLSessionUploader: ExportUploading {
    var session: URLSession = .shared

    func upload(file: URL, to target: ExportUploadTarget) async throws {
        var request = URLRequest(url: target.url)
        request.httpMethod = target.method
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (_, response) = try await session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw APIError.server(status: http.statusCode) }
        } catch let error as URLError {
            throw error.code == .cancelled ? CancellationError() : AppAttestClient.map(error)
        }
    }
}

protocol ExportLinkServing: Sendable {
    func create(sizeBytes: Int, sha256: String) async throws -> CreatedExportLink
    func upload(file: URL, to target: ExportUploadTarget) async throws
    func complete(exportLinkId: String) async throws -> ExportLinkSummary
    func current() async throws -> ExportLinkSummary?
    func revoke(exportLinkId: String) async throws
}

/// The `/export-links` endpoints. The file is encrypted before it gets here; the server never sees the key.
struct ExportLinkService: ExportLinkServing {
    var client: AppAttestClient = .shared
    var uploader: ExportUploading = URLSessionUploader()

    func create(sizeBytes: Int, sha256: String) async throws -> CreatedExportLink {
        try await client.signedPost("export-links", body: { challenge in
            CreateBody(challenge: challenge, sizeBytes: sizeBytes, sha256: sha256)
        }, response: CreatedExportLink.self)
    }

    func upload(file: URL, to target: ExportUploadTarget) async throws {
        try await uploader.upload(file: file, to: target)
    }

    func complete(exportLinkId: String) async throws -> ExportLinkSummary {
        try await client.signedPost("export-links/complete", body: { challenge in
            LinkBody(challenge: challenge, exportLinkId: exportLinkId)
        }, response: ExportLinkSummary.self)
    }

    func current() async throws -> ExportLinkSummary? {
        try await client.signedPost("export-links/current", body: { challenge in
            ChallengeBody(challenge: challenge)
        }, response: CurrentResponse.self).exportLink
    }

    func revoke(exportLinkId: String) async throws {
        _ = try await client.signedPost("export-links/revoke", body: { challenge in
            LinkBody(challenge: challenge, exportLinkId: exportLinkId)
        }, response: RevokedResponse.self)
    }

    struct CreateBody: Encodable, Equatable {
        let challenge: String
        let sizeBytes: Int
        let sha256: String
    }

    struct LinkBody: Encodable, Equatable {
        let challenge: String
        let exportLinkId: String
    }

    struct ChallengeBody: Encodable, Equatable {
        let challenge: String
    }

    struct CurrentResponse: Decodable {
        let exportLink: ExportLinkSummary?
    }

    private struct RevokedResponse: Decodable { let revoked: Bool }
}

/// What the app keeps so an open link can be shown again: the key exists nowhere else.
struct StoredExportLink: Codable, Equatable, Sendable {
    let exportLinkId: String
    let key: String
    let expiresAt: Date

    var link: String { ExportLinkCrypto.link(exportLinkId: exportLinkId, key: key) }

    func isExpired(now: Date) -> Bool { expiresAt <= now }
}

protocol ExportLinkStoring: Sendable {
    /// Nil when nothing is stored; a Keychain failure throws.
    func load() throws -> StoredExportLink?
    func save(_ link: StoredExportLink) throws
    func clear()
}

struct KeychainExportLinkStore: ExportLinkStoring {
    private static let log = Logger(subsystem: "com.thoughtreps", category: "KeychainExportLinkStore")
    private let service = "com.thoughtreps.exportlink"
    private let account = "current"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> StoredExportLink? {
        var item: CFTypeRef?
        let lookup = query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            Self.log.error("Keychain read failed: \(status)")
            throw KeychainStatusError(status: status)
        }
        if let link = try? JSONDecoder().decode(StoredExportLink.self, from: data) { return link }
        Self.log.error("Removed an unreadable export link item")
        clear()
        return nil
    }

    func save(_ link: StoredExportLink) throws {
        clear()
        let attributes = query.merging([
            kSecValueData as String: try JSONEncoder().encode(link),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("Keychain write failed: \(status)")
            throw KeychainStatusError(status: status)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
