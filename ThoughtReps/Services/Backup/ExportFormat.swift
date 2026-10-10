import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// `.thoughtreps` files: a zip archive whose first entry identifies it (see `BackupFormat`).
    static let thoughtRepsExport = UTType(exportedAs: BackupFormat.identifier, conformingTo: .zip)
}

/// The export file: a zip whose first entry is an uncompressed `mimetype` (so the signature sits at a
/// fixed offset, as in EPUB and ODF), then `manifest.json`, `tags.jsonl`, `thoughts.jsonl` and
/// `images/<uuid>` (the original image bytes; thumbnails are regenerated on import).
enum BackupFormat {
    static let identifier = "com.thoughtreps.export"
    static let mimeType = "application/vnd.thoughtreps.export+zip"
    static let fileExtension = "thoughtreps"
    static let currentVersion = 1

    static let mimetypePath = "mimetype"
    static let manifestPath = "manifest.json"
    static let tagsPath = "tags.jsonl"
    static let thoughtsPath = "thoughts.jsonl"
    static let imagePrefix = "images/"

    /// Temporary folders for an export being built and an import being read; swept at launch.
    static let exportDirectoryPrefix = "ThoughtRepsExport-"
    static let importDirectoryPrefix = "ThoughtRepsImport-"

    static func imagePath(for id: UUID) -> String {
        imagePrefix + id.uuidString
    }

    /// Only the canonical spelling counts, so one image has exactly one valid path.
    static func imageID(inPath path: String) -> UUID? {
        guard path.hasPrefix(imagePrefix), let id = UUID(uuidString: String(path.dropFirst(imagePrefix.count))),
              imagePath(for: id) == path
        else { return nil }
        return id
    }

    /// Where the `mimetype` entry's bytes start: a 30-byte local header plus the 8-byte name.
    static let signatureOffset = 38

    static func fileName(for date: Date) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return "ThoughtReps-export-\(day).\(fileExtension)"
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Sorted keys and fractional seconds, so the same data always gives the same bytes.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractional))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? fractional.parse(text)) ?? (try? whole.parse(text)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }

    static func hex(of digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

typealias BackupManifest = BackupFormatV1.Manifest
typealias TagRecord = BackupFormatV1.TagRecord
typealias ThoughtRecord = BackupFormatV1.ThoughtRecord
typealias BlockRecord = BackupFormatV1.BlockRecord
typealias ImageRecord = BackupFormatV1.ImageRecord

/// Format version 1. A change to any shape here is a new `BackupFormatV2` and a bumped `formatVersion`;
/// importers read the version first and decode with the matching types.
enum BackupFormatV1 {
    struct Manifest: Codable, Equatable {
        struct Counts: Codable, Equatable {
            var thoughts: Int
            var tags: Int
            var images: Int
        }

        var format: String
        var formatVersion: Int
        var appVersion: String
        var build: String
        var exportedAt: Date
        var counts: Counts
        /// SHA-256 (hex) of every entry except `mimetype` and this manifest, by path.
        var entries: [String: String]
    }

    struct TagRecord: Codable, Equatable {
        var name: String
        var displayName: String
        var colorHex: String?
        /// Absent in archives from before it existed; `updatedClock` then counts as the oldest.
        var updatedAt: Date? = nil
    }

    struct ImageRecord: Codable, Equatable {
        var id: UUID
        var width: Int
        var height: Int
        var order: Int
    }

    struct BlockRecord: Codable, Equatable {
        var id: UUID
        var kindRaw: String
        var title: String?
        var content: String
        var order: Int
        /// Markdown blocks only. Absent in archives from before it existed, which stored a blurred
        /// block as kind "blurred".
        var isBlurred: Bool
        /// Gallery blocks only.
        var images: [ImageRecord]

        init(id: UUID, kindRaw: String, title: String?, content: String, order: Int, isBlurred: Bool = false, images: [ImageRecord]) {
            self.id = id
            self.kindRaw = kindRaw
            self.title = title
            self.content = content
            self.order = order
            self.isBlurred = isBlurred
            self.images = images
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kindRaw = try container.decode(String.self, forKey: .kindRaw)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            content = try container.decode(String.self, forKey: .content)
            order = try container.decode(Int.self, forKey: .order)
            isBlurred = try container.decodeIfPresent(Bool.self, forKey: .isBlurred) ?? false
            images = try container.decode([ImageRecord].self, forKey: .images)
        }

        /// The kind and blur state this record stands for, mapping the old "blurred" kind; nil if unknown.
        var resolved: (kind: BlockKind, isBlurred: Bool)? {
            BlockKind.resolve(raw: kindRaw, isBlurred: isBlurred)
        }
    }

    struct ThoughtRecord: Codable, Equatable {
        var id: UUID
        var body: String
        var createdAt: Date
        var updatedAt: Date
        /// Change clocks of the schedule and state groups. Absent in archives from before they existed;
        /// `scheduleClock` and `stateClock` then fall back to `updatedAt`.
        var scheduleChangedAt: Date? = nil
        var stateChangedAt: Date? = nil
        var nextDueAt: Date
        var lastViewedAt: Date?
        var viewCount: Int
        var intervalDays: Int?
        var intervalModeRaw: String
        var learnIntervalDays: Int? = nil
        var isPinned: Bool
        var isArchived: Bool
        var archivedAt: Date?
        var tags: [String]
        var blocks: [BlockRecord]
        /// Inline images, the ones the body references with `![](img:<uuid>)`.
        var images: [ImageRecord]
    }
}

extension TagRecord {
    var updatedClock: Date { updatedAt ?? .distantPast }
}

extension ThoughtRecord {
    var scheduleClock: Date { scheduleChangedAt ?? updatedAt }
    var stateClock: Date { stateChangedAt ?? updatedAt }

    /// Whether importing this record keeps every `IntegrityChecker` invariant. Records written by the
    /// app always pass; anything else is skipped rather than repaired.
    var isImportable: Bool {
        let tokens = Set(inlineImageReferences)
        let inlineIDs = images.map(\.id)
        guard Set(inlineIDs).count == inlineIDs.count, tokens.isSubset(of: inlineIDs) else { return false }

        let galleryIDs = blocks.flatMap { $0.images.map(\.id) }
        guard Set(galleryIDs).count == galleryIDs.count, Set(galleryIDs).isDisjoint(with: inlineIDs),
              Set(blocks.map(\.id)).count == blocks.count
        else { return false }
        for block in blocks {
            guard let kind = block.resolved?.kind else { return false }
            switch kind {
            case .markdown:
                guard block.images.isEmpty, !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            case .gallery:
                guard !block.images.isEmpty, !block.isBlurred else { return false }
            }
        }
        guard (images + blocks.flatMap(\.images)).allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return false }

        if isArchived {
            guard !isPinned, archivedAt != nil else { return false }
        } else if archivedAt != nil {
            return false
        }
        if let days = intervalDays, !(1...Scheduler.maxIntervalDays).contains(days) { return false }
        if let days = learnIntervalDays {
            guard intervalModeRaw == IntervalMode.learn.rawValue, (1...Scheduler.maxIntervalDays).contains(days) else { return false }
        }
        return viewCount >= 0 && (viewCount == 0 || lastViewedAt != nil) && updatedAt >= createdAt
    }

    /// The body followed by the content of each markdown block, in block order.
    var markdownTexts: [String] {
        let ordered = blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
        return [body] + ordered.filter { $0.resolved?.kind == .markdown }.map(\.content)
    }

    /// Image ids referenced by tokens in `markdownTexts`.
    var inlineImageReferences: [UUID] {
        markdownTexts.flatMap { ImageToken.references(in: $0) }
    }

    /// Inline images first, then each gallery's.
    var imageIDs: [UUID] {
        images.map(\.id) + blocks.flatMap { $0.images.map(\.id) }
    }
}

enum BackupError: LocalizedError, Equatable {
    case notAnExport
    case needsNewerApp
    case damaged(String)
    case unsafe(String)
    case changedDuringExport

    var errorDescription: String? {
        switch self {
        case .notAnExport: "This isn't a Thought Reps export."
        case .needsNewerApp: "Update Thought Reps to import this file."
        case .damaged(let detail): "This export is damaged or incomplete (\(detail))."
        case .unsafe(let detail): "This file was rejected because it looks unsafe (\(detail))."
        case .changedDuringExport: "Your thoughts changed while exporting. Try again."
        }
    }
}
