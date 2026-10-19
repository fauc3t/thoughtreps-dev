#if DEBUG
import CryptoKit
import Foundation
import SwiftData

/// DEBUG only: one hash of everything that syncs between devices, for the two-device harness to compare. Two converged
/// devices give the same digest. It covers each thought's id, content, blocks, tags, pin/archive state, conflict link and
/// schedule fields, the change clocks (`updatedAt`, `scheduleChangedAt`, `stateChangedAt`), each tag's color and color
/// clock, and the SHA-256 of every image's and file's bytes. Clocks follow the winning side, so converged devices match,
/// and a writer that skips its clock shows up. It leaves out what differs per device or has no merge rule (view counters,
/// thumbnails).
///
/// Each thought is hashed on its own and the hashes are sorted before the final hash, so the order of storage doesn't matter.
/// Thoughts are read in pages through a fresh context each, so a big store is never held whole.
enum SyncContentDigest {
    struct Result: Equatable {
        var count: Int
        var digest: String
    }

    static let pageSize = 100

    static func compute(in container: ModelContainer) throws -> Result {
        let ids = try ModelContext(container).fetchIdentifiers(FetchDescriptor<Thought>())
        var hashes: [String] = []
        hashes.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: pageSize) {
            let page = Array(ids[start..<min(start + pageSize, ids.count)])
            let context = ModelContext(container)
            let found = try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { page.contains($0.persistentModelID) }))
            for thought in found { hashes.append(hex(SHA256.hash(data: Data(canonical(thought).utf8)))) }
        }
        hashes.sort()
        return Result(count: hashes.count, digest: hex(SHA256.hash(data: Data(hashes.joined(separator: "\n").utf8))))
    }

    static func canonical(_ thought: Thought) -> String {
        var lines = [
            "thought \(thought.id.uuidString)",
            "body \(escaped(thought.body))",
            "created \(date(thought.createdAt)) updated \(date(thought.updatedAt))",
            "clocks schedule \(date(thought.scheduleChangedAt)) state \(date(thought.stateChangedAt))",
            "pinned \(thought.isPinned) archived \(thought.isArchived) archivedAt \(thought.archivedAt.map(date) ?? "-")",
            "conflictOf \(thought.conflictOfID?.uuidString ?? "-")",
            "due \(date(thought.nextDueAt)) interval \(thought.intervalDays.map(String.init) ?? "-")",
            "mode \(thought.intervalModeRaw) learn \(thought.learnIntervalDays.map(String.init) ?? "-")",
            "tags \((thought.tags ?? []).map { "\($0.name) \($0.colorHex ?? "-") \(date($0.updatedAt))" }.sorted().joined(separator: ","))",
        ]
        for block in (thought.blocks ?? []).sorted(by: { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }) {
            lines.append(
                "block \(block.id.uuidString) \(block.kindRaw) \(block.order) blurred \(block.isBlurred) "
                + "link \(block.linkedThoughtID?.uuidString ?? "-") title \(block.title.map(escaped) ?? "-") \(escaped(block.content))"
            )
        }
        for image in (thought.images ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append(
                "image \(image.id.uuidString) \(image.width)x\(image.height) order \(image.order) "
                + "block \(image.block?.id.uuidString ?? "-") \(image.data.map { hex(SHA256.hash(data: $0)) } ?? "missing")"
            )
        }
        for file in (thought.files ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append(
                "file \(file.id.uuidString) \(escaped(file.filename)) \(file.typeIdentifier) \(file.byteCount) "
                + "block \(file.block?.id.uuidString ?? "-") \(file.data.map { hex(SHA256.hash(data: $0)) } ?? "missing")"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func date(_ value: Date) -> String { "\(value.timeIntervalSinceReferenceDate)" }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
