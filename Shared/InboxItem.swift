import Foundation

/// One thought handed from the share extension to the app. Encoded as `<id>.json` in the inbox.
struct InboxItem: Codable, Equatable, Sendable {
    /// A file shared with the thought, copied into the inbox as `path` (relative to the inbox).
    /// Items written before attachments existed decode with none.
    struct Attachment: Codable, Equatable, Sendable {
        var filename: String
        var typeIdentifier: String
        var path: String
    }

    var id: UUID
    var body: String
    var createdAt: Date
    var attachment: Attachment?

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// The inbox directory in the App Group container, and atomic writes into it.
enum Inbox {
    static let groupInfoKey = "TRAppGroupIdentifier"
    static let directoryName = "Inbox"

    enum InboxError: Error {
        case missingAppGroup
    }

    /// Resolves (and creates) the inbox from the App Group ID in this bundle's Info.plist.
    static func directoryURL(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> URL {
        guard let group = bundle.object(forInfoDictionaryKey: groupInfoKey) as? String,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw InboxError.missingAppGroup }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func attachmentPath(for id: UUID) -> String {
        "\(id.uuidString).attachment"
    }

    /// Where the extension holds a shared file until the user saves; private to the extension.
    static func stagingURL(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(attachmentPath(for: id))
    }

    /// Copies a shared file into the inbox without reading it into memory, and returns its relative path.
    /// Write the item that names it afterwards: an attachment with no item is an orphan the app deletes.
    static func copyAttachment(
        from source: URL, id: UUID, to directory: URL, name: String? = nil, fileManager: FileManager = .default
    ) throws -> String {
        let path = name ?? attachmentPath(for: id)
        let destination = directory.appendingPathComponent(path)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        return path
    }

    /// Writes to a temp name, then renames to `<id>.json`, so a reader never sees a partial file.
    /// The temp name has no `.json` extension, so the importer ignores it.
    static func write(_ item: InboxItem, to directory: URL, fileManager: FileManager = .default) throws {
        let data = try InboxItem.encoder().encode(item)
        let temp = directory.appendingPathComponent("\(item.id.uuidString).tmp")
        let final = directory.appendingPathComponent("\(item.id.uuidString).json")
        do {
            try data.write(to: temp)
            _ = try fileManager.replaceItemAt(final, withItemAt: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
