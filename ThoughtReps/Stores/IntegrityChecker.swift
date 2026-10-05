import Foundation
import SwiftData
import os

/// Read-only audit of the invariants the store is meant to maintain. Never repairs anything.
/// Orphan tags are allowed: they are pruned at launch, not on every write.
@MainActor
enum IntegrityChecker {
    struct Violation: CustomStringConvertible, Equatable {
        let description: String
        /// The thought's id, the tag's name, or the block's/image's id.
        let modelID: String?
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "integrity")

    static func logViolations(in context: ModelContext) {
        do {
            for violation in try check(context) {
                logger.error("Integrity violation: \(violation.description)")
            }
        } catch {
            logger.error("Integrity check failed to fetch: \(error)")
        }
    }

    static func check(_ context: ModelContext) throws -> [Violation] {
        var found: [Violation] = []
        func add(_ description: String, _ id: String?) {
            found.append(Violation(description: description, modelID: id))
        }

        let thoughts = try context.fetch(FetchDescriptor<Thought>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let blocks = try context.fetch(FetchDescriptor<Block>())
        let images = try context.fetch(FetchDescriptor<ImageAsset>())

        var seenNames = Set<String>()
        for tag in tags {
            if tag.name != tag.name.precomposedStringWithCanonicalMapping.lowercased() {
                add("Tag name '\(tag.name)' is not lowercased NFC", tag.name)
            }
            if !seenNames.insert(tag.name).inserted {
                add("Duplicate tag name '\(tag.name)'", tag.name)
            }
            if tag.displayName.isEmpty {
                add("Tag '\(tag.name)' has an empty displayName", tag.name)
            }
            for thought in tag.thoughts ?? [] where !(thought.tags ?? []).contains(where: { $0 === tag }) {
                add("Tag '\(tag.name)' lists thought \(thought.id) which does not list it back", tag.name)
            }
        }

        for block in blocks {
            guard let owner = block.thought else {
                add("Block \(block.id) has no thought", block.id.uuidString)
                continue
            }
            if !(owner.blocks ?? []).contains(where: { $0 === block }) {
                add("Block \(block.id) points to thought \(owner.id) which does not list it", block.id.uuidString)
            }
        }
        for image in images {
            guard let owner = image.thought else {
                add("Image \(image.id) has no thought", image.id.uuidString)
                continue
            }
            if !(owner.images ?? []).contains(where: { $0 === image }) {
                add("Image \(image.id) points to thought \(owner.id) which does not list it", image.id.uuidString)
            }
        }

        for thought in thoughts {
            let id = thought.id.uuidString

            let expectedTags = Set(TagParser.parse(thought.body).map(\.key))
            let actualTags = (thought.tags ?? []).map(\.name)
            if Set(actualTags) != expectedTags || actualTags.count != expectedTags.count {
                add("Thought \(id) tags \(actualTags.sorted()) != parsed \(expectedTags.sorted())", id)
            }
            for tag in thought.tags ?? [] where !(tag.thoughts ?? []).contains(where: { $0 === thought }) {
                add("Thought \(id) lists tag '\(tag.name)' which does not list it back", id)
            }
            for block in thought.blocks ?? [] where block.thought !== thought {
                add("Thought \(id) lists block \(block.id) whose thought differs", id)
            }
            for image in thought.images ?? [] where image.thought !== thought {
                add("Thought \(id) lists image \(image.id) whose thought differs", id)
            }

            let orders = (thought.blocks ?? []).map(\.order).sorted()
            if orders != Array(0..<orders.count) {
                add("Thought \(id) block orders \(orders) are not 0..<\(orders.count)", id)
            }

            if thought.isArchived {
                if thought.isPinned { add("Thought \(id) is archived and pinned", id) }
                if thought.archivedAt == nil { add("Thought \(id) is archived without archivedAt", id) }
            } else if thought.archivedAt != nil {
                add("Thought \(id) is not archived but has archivedAt", id)
            }

            if thought.viewCount < 0 { add("Thought \(id) has negative viewCount", id) }
            if thought.viewCount > 0 && thought.lastViewedAt == nil {
                add("Thought \(id) has views but no lastViewedAt", id)
            }
            if thought.updatedAt < thought.createdAt { add("Thought \(id) updatedAt precedes createdAt", id) }

            if let days = thought.intervalDays, !(1...Scheduler.maxIntervalDays).contains(days) {
                add("Thought \(id) intervalDays \(days) is out of range", id)
            }
        }
        return found
    }
}
