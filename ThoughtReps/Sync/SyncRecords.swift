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

/// Content group of a thought: what `updatedAt` covers.
struct ThoughtContentRecord: Codable, Equatable, Sendable {
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
        case .thoughtContent(let record): return try wrap(record)
        case .thoughtMeta(let record): return try wrap(record)
        case .tag(let record): return try wrap(record)
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

    static func decode(_ data: Data) throws -> SyncPayload {
        let decoder = Self.decoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.v >= 1, header.v <= currentVersion else { throw Failure.unsupportedVersion(header.v) }
        guard let type = SyncRecordType(rawValue: header.type) else { throw Failure.unknownType(header.type) }
        if header.deleted {
            guard type == .thoughtContent || type == .thoughtMeta else { throw Failure.invalid }
            return .deletion(type, try decoder.decode(Envelope<SyncDeletion>.self, from: data).data)
        }
        switch type {
        case .thoughtContent: return .thoughtContent(try decoder.decode(Envelope<ThoughtContentRecord>.self, from: data).data)
        case .thoughtMeta: return .thoughtMeta(try decoder.decode(Envelope<ThoughtMetaRecord>.self, from: data).data)
        case .tag: return .tag(try decoder.decode(Envelope<TagRecord>.self, from: data).data)
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
