import CryptoKit
import Foundation

/// Encrypts an export for an export link. The file is `"TRB1"` + a 12-byte nonce + ciphertext + a 16-byte
/// AES-256-GCM tag, and the key travels only in the link's URL fragment, which browsers never send.
enum ExportLinkCrypto {
    static let magic = Data("TRB1".utf8)
    static let maxEncryptedBytes = 100 * 1024 * 1024
    static let overheadBytes = 4 + 12 + 16
    static let linkBase = "https://transfer.thoughtreps.com/x/"

    enum Failure: Error, Equatable {
        case tooLarge
    }

    struct EncryptedFile: Equatable, Sendable {
        let sizeBytes: Int
        let sha256: String
    }

    static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func checkSize(plainBytes: Int) throws {
        guard plainBytes + overheadBytes <= maxEncryptedBytes else { throw Failure.tooLarge }
    }

    static func encrypt(_ plain: Data, key: SymmetricKey) throws -> Data {
        var file = Data(capacity: plain.count + overheadBytes)
        try seal(plain, key: key) { file.append($0) }
        return file
    }

    /// Writes the file piece by piece and hashes as it goes, so only the sealed copy sits in memory beside
    /// the (memory-mapped) archive. Refuses before reading when the result would exceed the upload limit.
    static func encryptFile(at source: URL, to destination: URL, key: SymmetricKey) throws -> EncryptedFile {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try checkSize(plainBytes: size)
        let plain = try Data(contentsOf: source, options: .mappedIfSafe)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var written = 0
        do {
            try seal(plain, key: key) { piece in
                try handle.write(contentsOf: piece)
                hasher.update(data: piece)
                written += piece.count
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return EncryptedFile(sizeBytes: written, sha256: Data(hasher.finalize()).base64EncodedString())
    }

    private static func seal(_ plain: Data, key: SymmetricKey, emit: (Data) throws -> Void) throws {
        try checkSize(plainBytes: plain.count)
        let box = try AES.GCM.seal(plain, using: key)
        try emit(magic)
        try emit(Data(box.nonce))
        try emit(box.ciphertext)
        try emit(box.tag)
    }

    static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func base64URL(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func link(exportLinkId: String, key: String) -> String {
        "\(linkBase)\(exportLinkId)#\(key)"
    }
}
