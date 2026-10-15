import CryptoKit
import Foundation

/// The ids and content of a conflict copy (spec section 8a). Everything is derived from the original's id and the
/// losing content, so devices that make the same copy independently end up with one thought, not two.
enum ConflictCopy {
    /// Which version of a collision a side is.
    enum Side: Equatable, Sendable {
        case local
        case remote
    }

    static func copyID(of original: UUID, losing content: ThoughtContentRecord) -> UUID {
        let plaintext = (try? SyncPayload.thoughtContent(content).encoded()) ?? Data()
        return derivedID("copy|\(original.uuidString)|\(SyncPayload.hash(of: plaintext))")
    }

    /// The id a block, image or file gets in the thought `parent` that takes over a copy of `source`.
    static func derivedID(parent: UUID, source: UUID) -> UUID {
        derivedID("child|\(parent.uuidString)|\(source.uuidString)")
    }

    private static func derivedID(_ name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The same content as the thought `id`: new ids for the blocks, images and files (the old ones belong to the
    /// other thought), and the inline image tokens in the text rewritten to match. Links to other thoughts stay.
    static func content(_ source: ThoughtContentRecord, as id: UUID) -> ThoughtContentRecord {
        func child(_ old: UUID) -> UUID { derivedID(parent: id, source: old) }
        func image(_ record: ImageRecord) -> ImageRecord {
            var copy = record
            copy.id = child(record.id)
            return copy
        }
        let inlineIDs = source.images.map(\.id)
        func text(_ text: String) -> String {
            inlineIDs.reduce(text) { text, old in
                text.replacingOccurrences(of: "(\(ImageToken.scheme):\(old.uuidString))", with: "(\(ImageToken.scheme):\(child(old).uuidString))", options: .caseInsensitive)
            }
        }
        return ThoughtContentRecord(
            id: id, body: text(source.body), createdAt: source.createdAt, updatedAt: source.updatedAt,
            blocks: source.blocks.map { block in
                var copy = block
                copy.id = child(block.id)
                if block.resolved?.kind == .markdown { copy.content = text(block.content) }
                copy.images = block.images.map(image)
                copy.file = block.file.map { file in
                    var renamed = file
                    renamed.id = child(file.id)
                    return renamed
                }
                return copy
            },
            images: source.images.map(image)
        )
    }

    /// The content without the images and files whose bytes aren't available: their tokens (and the line, if the
    /// token was all of it) and gallery entries go, and so do galleries, file blocks and markdown blocks left empty by that.
    static func keepingAssets(of source: ThoughtContentRecord, imageIDs: Set<UUID>, fileIDs: Set<UUID>) -> ThoughtContentRecord {
        let lostInline = Set(source.images.map(\.id)).subtracting(imageIDs)
        func text(_ text: String) -> String {
            guard !lostInline.isEmpty else { return text }
            return ContentMerge.lines(text).compactMap { line in
                guard ImageToken.references(in: line).contains(where: lostInline.contains) else { return line }
                let rest = ImageToken.removing(lostInline, from: line)
                return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rest
            }.joined(separator: "\n")
        }
        var result = source
        result.body = text(source.body)
        result.images = source.images.filter { imageIDs.contains($0.id) }
        result.blocks = source.blocks.compactMap { (block: BlockRecord) -> BlockRecord? in
            var kept = block
            switch block.resolved?.kind {
            case .markdown:
                kept.content = text(block.content)
                if kept.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            case .gallery:
                kept.images = block.images.filter { imageIDs.contains($0.id) }
                if kept.images.isEmpty { return nil }
            case .file:
                guard let file = block.file, fileIDs.contains(file.id) else { return nil }
            default:
                break
            }
            return kept
        }
        .enumerated().map { (index: Int, block: BlockRecord) -> BlockRecord in
            var numbered = block
            numbered.order = index
            return numbered
        }
        return result
    }
}
