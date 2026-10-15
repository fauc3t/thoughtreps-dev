import CryptoKit
import Foundation

/// The four kinds of sync record. A thought is two: its content and its meta (schedule, state, counters).
enum SyncRecordType: String, Sendable, CaseIterable {
    case thoughtContent = "thought.content"
    case thoughtMeta = "thought.meta"
    case tag
    case settings
}

/// The things a local write can change; what the outbox holds. A thought's records are derived from it at push time.
enum SyncEntityKind: String, Sendable {
    case thought
    case tag
    case settings
}

struct SyncEntity: Hashable, Sendable {
    var kind: SyncEntityKind
    /// A thought's uuid string, a tag's `name`, or `settingsID` for the settings record.
    var id: String

    static let settingsID = "settings"

    static func thought(_ id: UUID) -> SyncEntity { SyncEntity(kind: .thought, id: id.uuidString) }
    static func tag(_ name: String) -> SyncEntity { SyncEntity(kind: .tag, id: name) }
    static let settings = SyncEntity(kind: .settings, id: settingsID)
}

/// Content group of a thought: what `updatedAt` covers. It is held in the backup's record types but goes over the
/// wire as `SyncWireV1.Content`, so a change to the backup format can't change a sync payload.
struct ThoughtContentRecord: Equatable, Sendable {
    var id: UUID
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var blocks: [BlockRecord]
    /// Inline images, the ones the body references with `![](img:<uuid>)`.
    var images: [ImageRecord]
}

/// Schedule, state and counters of a thought, each group on its own clock (see `ThoughtRecord`).
struct ThoughtMetaRecord: Codable, Equatable, Sendable {
    var id: UUID
    var nextDueAt: Date
    var intervalDays: Int?
    var intervalModeRaw: String
    var learnIntervalDays: Int?
    var scheduleChangedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    var archivedAt: Date?
    var conflictOfID: UUID?
    var stateChangedAt: Date
    var viewCount: Int
    var lastViewedAt: Date?
}

struct SettingsRecord: Codable, Equatable, Sendable {
    var defaultIntervalDays: Int
    /// When the user last changed it; `distantPast` if never, so any real change wins.
    var changedAt: Date
}

/// A thought deleted on some device; written to both of the thought's records.
struct SyncDeletion: Codable, Equatable, Sendable {
    var id: UUID
    var deletedAt: Date
}

/// The JSON shapes of the record bodies that carry backup-format values, frozen for sync: a field is never renamed or
/// retyped, and a new shape is a new payload version. Optionals that are nil are left out of the JSON; the known-answer
/// tests pin the exact bytes.
enum SyncWireV1 {
    struct Image: Codable, Equatable {
        var id: UUID
        var width: Int
        var height: Int
        var order: Int
    }

    struct File: Codable, Equatable {
        var id: UUID
        var filename: String
        var typeIdentifier: String
        var byteCount: Int
    }

    struct Block: Codable, Equatable {
        var id: UUID
        var kindRaw: String
        var title: String?
        var content: String
        var order: Int
        var isBlurred: Bool
        var images: [Image]
        var linkedThoughtID: UUID?
        var file: File?
    }

    struct Tag: Codable, Equatable {
        var name: String
        var displayName: String
        var colorHex: String?
        var updatedAt: Date?
    }

    struct Content: Codable, Equatable {
        var id: UUID
        var body: String
        var createdAt: Date
        var updatedAt: Date
        var blocks: [Block]
        var images: [Image]
    }
}

extension SyncWireV1.Block {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kindRaw = try container.decode(String.self, forKey: .kindRaw)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        order = try container.decode(Int.self, forKey: .order)
        isBlurred = try container.decodeIfPresent(Bool.self, forKey: .isBlurred) ?? false
        images = try container.decode([SyncWireV1.Image].self, forKey: .images)
        linkedThoughtID = try container.decodeIfPresent(UUID.self, forKey: .linkedThoughtID)
        file = try container.decodeIfPresent(SyncWireV1.File.self, forKey: .file)
    }
}

extension SyncWireV1.Image {
    init(_ image: ImageRecord) {
        self.init(id: image.id, width: image.width, height: image.height, order: image.order)
    }

    var record: ImageRecord { ImageRecord(id: id, width: width, height: height, order: order) }
}

extension SyncWireV1.File {
    init(_ file: FileRecord) {
        self.init(id: file.id, filename: file.filename, typeIdentifier: file.typeIdentifier, byteCount: file.byteCount)
    }

    var record: FileRecord { FileRecord(id: id, filename: filename, typeIdentifier: typeIdentifier, byteCount: byteCount) }
}

extension SyncWireV1.Block {
    init(_ block: BlockRecord) {
        self.init(
            id: block.id, kindRaw: block.kindRaw, title: block.title, content: block.content, order: block.order,
            isBlurred: block.isBlurred, images: block.images.map(SyncWireV1.Image.init), linkedThoughtID: block.linkedThoughtID,
            file: block.file.map(SyncWireV1.File.init)
        )
    }

    var record: BlockRecord {
        BlockRecord(
            id: id, kindRaw: kindRaw, title: title, content: content, order: order, isBlurred: isBlurred,
            images: images.map(\.record), linkedThoughtID: linkedThoughtID, file: file?.record
        )
    }
}

extension SyncWireV1.Tag {
    init(_ tag: TagRecord) {
        self.init(name: tag.name, displayName: tag.displayName, colorHex: tag.colorHex, updatedAt: tag.updatedAt)
    }

    var record: TagRecord { TagRecord(name: name, displayName: displayName, colorHex: colorHex, updatedAt: updatedAt) }
}

extension SyncWireV1.Content {
    init(_ content: ThoughtContentRecord) {
        self.init(
            id: content.id, body: content.body, createdAt: content.createdAt, updatedAt: content.updatedAt,
            blocks: content.blocks.map(SyncWireV1.Block.init), images: content.images.map(SyncWireV1.Image.init)
        )
    }

    var record: ThoughtContentRecord {
        ThoughtContentRecord(
            id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, blocks: blocks.map(\.record), images: images.map(\.record)
        )
    }
}

extension ThoughtContentRecord {
    init(_ record: ThoughtRecord) {
        self.init(
            id: record.id, body: record.body, createdAt: record.createdAt, updatedAt: record.updatedAt,
            blocks: record.blocks, images: record.images
        )
    }

    @MainActor
    init(_ thought: Thought) {
        self.init(ThoughtRecord(thought, hasImage: { _ in true }))
    }
}

extension ThoughtMetaRecord {
    init(_ record: ThoughtRecord) {
        self.init(
            id: record.id, nextDueAt: record.nextDueAt, intervalDays: record.intervalDays, intervalModeRaw: record.intervalModeRaw,
            learnIntervalDays: record.learnIntervalDays, scheduleChangedAt: record.scheduleClock, isPinned: record.isPinned,
            isArchived: record.isArchived, archivedAt: record.archivedAt, conflictOfID: record.conflictOfID,
            stateChangedAt: record.stateClock, viewCount: record.viewCount, lastViewedAt: record.lastViewedAt
        )
    }

    @MainActor
    init(_ thought: Thought) {
        self.init(ThoughtRecord(thought, hasImage: { _ in true }))
    }
}

extension SettingsRecord {
    static func current(defaults: UserDefaults = .standard) -> SettingsRecord {
        SettingsRecord(
            defaultIntervalDays: AppSettings.defaultIntervalDays(in: defaults),
            changedAt: AppSettings.defaultIntervalChangedAt(in: defaults)
        )
    }
}

/// One record's plaintext, before sealing. The JSON is `{"v":1,"type":...,"deleted":...,"data":{...}}`
/// with sorted keys, so the same record always gives the same bytes (and hash).
enum SyncPayload: Equatable, Sendable {
    case thoughtContent(ThoughtContentRecord)
    case thoughtMeta(ThoughtMetaRecord)
    case tag(TagRecord)
    case settings(SettingsRecord)
    /// Only for the two thought record types.
    case deletion(SyncRecordType, SyncDeletion)

    static let currentVersion = 1

    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case unknownType(String)
        case invalid
    }

    var type: SyncRecordType {
        switch self {
        case .thoughtContent: .thoughtContent
        case .thoughtMeta: .thoughtMeta
        case .tag: .tag
        case .settings: .settings
        case .deletion(let type, _): type
        }
    }

    var isDeletion: Bool {
        if case .deletion = self { return true }
        return false
    }

    /// The id used in `SyncEntity` and for the record key.
    var entityID: String {
        switch self {
        case .thoughtContent(let record): record.id.uuidString
        case .thoughtMeta(let record): record.id.uuidString
        case .tag(let record): record.name
        case .settings: SyncEntity.settingsID
        case .deletion(_, let deletion): deletion.id.uuidString
        }
    }

    var fingerprint: String {
        switch self {
        case .thoughtContent(let record): SyncFingerprint.content(updatedAt: record.updatedAt)
        case .thoughtMeta(let record):
            SyncFingerprint.meta(
                scheduleChangedAt: record.scheduleChangedAt, stateChangedAt: record.stateChangedAt,
                viewCount: record.viewCount, lastViewedAt: record.lastViewedAt
            )
        case .tag(let record): SyncFingerprint.tag(updatedAt: record.updatedClock)
        case .settings(let record): SyncFingerprint.settings(changedAt: record.changedAt)
        case .deletion(_, let deletion): SyncFingerprint.deletion(deletedAt: deletion.deletedAt)
        }
    }

    private struct Envelope<Body: Codable>: Codable {
        var v: Int
        var type: String
        var deleted: Bool
        var data: Body
    }

    private struct Header: Decodable {
        var v: Int
        var type: String
        var deleted: Bool
    }

    func encoded() throws -> Data {
        let encoder = Self.encoder()
        func wrap<Body: Codable>(_ body: Body, deleted: Bool = false) throws -> Data {
            try encoder.encode(Envelope(v: Self.currentVersion, type: type.rawValue, deleted: deleted, data: body))
        }
        switch self {
        case .thoughtContent(let record): return try wrap(SyncWireV1.Content(record))
        case .thoughtMeta(let record): return try wrap(record)
        case .tag(let record): return try wrap(SyncWireV1.Tag(record))
        case .settings(let record): return try wrap(record)
        case .deletion(_, let deletion): return try wrap(deletion, deleted: true)
        }
    }

    /// Dates use `.deferredToDate`: exact `Double` seconds since the reference date, which JSON round-trips losslessly
    /// (not the backup's ISO 8601 strings, which are cut to the millisecond).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    static func decode(_ data: Data, supporting maxVersion: Int = currentVersion) throws -> SyncPayload {
        let decoder = Self.decoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.v >= 1, header.v <= maxVersion else { throw Failure.unsupportedVersion(header.v) }
        guard let type = SyncRecordType(rawValue: header.type) else { throw Failure.unknownType(header.type) }
        if header.deleted {
            guard type == .thoughtContent || type == .thoughtMeta else { throw Failure.invalid }
            return .deletion(type, try decoder.decode(Envelope<SyncDeletion>.self, from: data).data)
        }
        switch type {
        case .thoughtContent: return .thoughtContent(try decoder.decode(Envelope<SyncWireV1.Content>.self, from: data).data.record)
        case .thoughtMeta: return .thoughtMeta(try decoder.decode(Envelope<ThoughtMetaRecord>.self, from: data).data)
        case .tag: return .tag(try decoder.decode(Envelope<SyncWireV1.Tag>.self, from: data).data.record)
        case .settings: return .settings(try decoder.decode(Envelope<SettingsRecord>.self, from: data).data)
        }
    }

    /// SHA-256 (hex) of the plaintext JSON.
    static func hash(of plaintext: Data) -> String {
        BackupFormat.hex(of: SHA256.hash(data: plaintext))
    }
}

/// What a record looked like when it was last synced: the exact value of each clock, so a record
/// applied from the wire fingerprints the same as the one that was sent.
///
/// A fingerprint is for drift detection only (the reconciler, "is there anything to push?"). Some
/// content changes don't move `updatedAt` (such as removing tokenless inline images), so equal
/// fingerprints don't prove equal content: the engine must push every outbox entry and use the base
/// hash of the sealed payload, not fingerprint equality, to skip a no-op.
enum SyncFingerprint {
    static func exact(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    static func content(updatedAt: Date) -> String {
        "c\(exact(updatedAt))"
    }

    static func meta(scheduleChangedAt: Date, stateChangedAt: Date, viewCount: Int, lastViewedAt: Date?) -> String {
        "m\(exact(scheduleChangedAt)).\(exact(stateChangedAt)).\(viewCount).\(lastViewedAt.map { String(exact($0)) } ?? "-")"
    }

    static func tag(updatedAt: Date) -> String {
        "t\(exact(updatedAt))"
    }

    static func settings(changedAt: Date) -> String {
        "s\(exact(changedAt))"
    }

    static func deletion(deletedAt: Date) -> String {
        "d\(exact(deletedAt))"
    }
}
