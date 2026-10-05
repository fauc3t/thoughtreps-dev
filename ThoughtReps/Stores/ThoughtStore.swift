import Foundation
import SwiftData
import os

/// Draft of a block being edited, before it is written to the store.
struct BlockDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: BlockKind = .blurred
    var title: String = ""
    var content: String = ""
}

/// All writes go through here so tag syncing and scheduling rules are applied in one place.
/// Every time-dependent method takes `now` from the caller, so tests control the clock.
@MainActor
struct ThoughtStore {
    let context: ModelContext
    var defaultIntervalDays: Int = AppSettings.defaultIntervalDays
    var saveErrors: SaveErrorCenter = .shared
    /// Seam so tests can force a save failure.
    var save: (ModelContext) throws -> Void = { try $0.save() }

    // MARK: Create & edit

    /// If the save fails, the change is rolled back and the returned thought is detached
    /// (`modelContext == nil`). That is how callers tell a save failed; the other writers return a Bool.
    @discardableResult
    func create(body: String, blocks: [BlockDraft] = [], intervalDays: Int? = nil, now: Date) -> Thought {
        let interval = intervalDays ?? defaultIntervalDays
        let thought = Thought(
            body: body,
            createdAt: now,
            nextDueAt: Scheduler.firstDue(createdAt: now, intervalDays: interval),
            intervalDays: intervalDays
        )
        context.insert(thought)
        syncTags(for: thought)
        insert(reuseBlocks(of: thought, for: blocks).additions, into: thought)
        persist()
        return thought
    }

    @discardableResult
    func update(_ thought: Thought, body: String, blocks: [BlockDraft], intervalDays: Int?, now: Date) -> Bool {
        guard saveNewTags(for: body) else { return false }
        let intervalChanged = thought.intervalDays != intervalDays
        thought.body = body
        thought.intervalDays = intervalDays
        if intervalChanged {
            reanchor(thought)
        }
        thought.updatedAt = now
        syncTags(for: thought)
        let plan = reuseBlocks(of: thought, for: blocks)
        guard persist() else { return false }
        if !plan.surplus.isEmpty {
            for block in plan.surplus {
                block.thought = nil
                context.delete(block)
            }
            guard persist() else { return false }
        }
        if !plan.additions.isEmpty {
            insert(plan.additions, into: thought)
            return persist()
        }
        return true
    }

    private struct BlockContent {
        let id: UUID
        let kind: BlockKind
        let content: String
        let title: String?
        var order = 0
    }

    /// Edits the thought's existing blocks in place and returns the blocks to delete and to add
    /// (blank drafts are dropped). The caller saves those separately; see `persist()`.
    private func reuseBlocks(of thought: Thought, for drafts: [BlockDraft]) -> (surplus: [Block], additions: [BlockContent]) {
        let existing = thought.sortedBlocks
        var kept = drafts.compactMap { draft -> BlockContent? in
            let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return BlockContent(id: draft.id, kind: draft.kind, content: content, title: title.isEmpty ? nil : title)
        }
        for index in kept.indices {
            kept[index].order = index
        }
        for (index, item) in kept.prefix(existing.count).enumerated() {
            let block = existing[index]
            block.id = item.id
            block.kindRaw = item.kind.rawValue
            block.content = item.content
            block.title = item.title
            block.order = index
        }
        return (Array(existing.dropFirst(kept.count)), Array(kept.dropFirst(existing.count)))
    }

    private func insert(_ items: [BlockContent], into thought: Thought) {
        for item in items {
            let block = Block(id: item.id, kind: item.kind, content: item.content, title: item.title, order: item.order)
            context.insert(block)
            block.thought = thought
        }
    }

    /// Rebuilds the thought's tags from its body, creating `Tag`s as needed.
    func syncTags(for thought: Thought) {
        let wanted = TagParser.parse(thought.body).map(tag(for:))
        let wantedNames = Set(wanted.map(\.name))
        thought.tags?.removeAll { !wantedNames.contains($0.name) }
        let existing = Set((thought.tags ?? []).map(\.name))
        for tag in wanted where !existing.contains(tag.name) {
            thought.tags?.append(tag)
        }
    }

    /// Saves tags the body needs that don't exist yet, before the thought is edited; see `persist()`.
    private func saveNewTags(for body: String) -> Bool {
        var inserted = false
        for parsed in TagParser.parse(body) where existingTag(named: parsed.key) == nil {
            context.insert(Tag(name: parsed.key, displayName: parsed.display))
            inserted = true
        }
        return !inserted || persist()
    }

    private func existingTag(named key: String) -> Tag? {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func tag(for parsed: TagParser.ParsedTag) -> Tag {
        if let existing = existingTag(named: parsed.key) {
            return existing
        }
        let tag = Tag(name: parsed.key, displayName: parsed.display)
        context.insert(tag)
        return tag
    }

    // MARK: Schedule actions

    @discardableResult
    func markViewed(_ thought: Thought, now: Date) -> Bool {
        thought.applyView(defaultIntervalDays: defaultIntervalDays, now: now)
        return persist()
    }

    @discardableResult
    func snooze(_ thought: Thought, days: Int, now: Date) -> Bool {
        thought.applySnooze(days: days, now: now)
        return persist()
    }

    @discardableResult
    func setInterval(_ thought: Thought, days: Int?, now: Date) -> Bool {
        thought.intervalDays = days
        reanchor(thought)
        thought.updatedAt = now
        return persist()
    }

    private func reanchor(_ thought: Thought) {
        thought.nextDueAt = Scheduler.reanchoredDue(
            createdAt: thought.createdAt,
            lastViewedAt: thought.lastViewedAt,
            intervalDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
        )
    }

    @discardableResult
    func setPinned(_ thought: Thought, _ pinned: Bool) -> Bool {
        thought.isPinned = pinned && !thought.isArchived
        return persist()
    }

    @discardableResult
    func archive(_ thought: Thought, now: Date) -> Bool {
        thought.isArchived = true
        thought.isPinned = false
        thought.archivedAt = now
        return persist()
    }

    @discardableResult
    func restore(_ thought: Thought, now: Date) -> Bool {
        thought.isArchived = false
        thought.archivedAt = nil
        thought.nextDueAt = Scheduler.restoredDue(now: now)
        return persist()
    }

    @discardableResult
    func delete(_ thought: Thought) -> Bool {
        deleteWithChildren(thought)
        return persist()
    }

    /// Deletes blocks and images explicitly rather than by cascade; see `persist()`.
    private func deleteWithChildren(_ thought: Thought) {
        for block in thought.blocks ?? [] {
            block.thought = nil
            context.delete(block)
        }
        for image in thought.images ?? [] {
            image.thought = nil
            context.delete(image)
        }
        context.delete(thought)
    }

    /// Deletes every thought and tag. One by one, because batch deletes can leave
    /// @Query results stale on iOS 17.
    @discardableResult
    func deleteAll() -> Bool {
        for thought in (try? context.fetch(FetchDescriptor<Thought>())) ?? [] {
            deleteWithChildren(thought)
        }
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] {
            context.delete(tag)
        }
        return persist()
    }

    /// Sets schedule fields directly, bypassing the rules. Only for sample data,
    /// which needs thoughts in every state.
    @discardableResult
    func overrideSchedule(_ thought: Thought, nextDueAt: Date, lastViewedAt: Date?, viewCount: Int) -> Bool {
        thought.nextDueAt = nextDueAt
        thought.lastViewedAt = lastViewedAt
        thought.viewCount = viewCount
        return persist()
    }

    /// Deletes tags that no thought (active or archived) uses any more.
    ///
    /// Call at launch only: a tag timeline on the navigation stack holds its `Tag`, and
    /// reading a deleted model can crash. Until then, empty tags are simply hidden.
    @discardableResult
    func pruneOrphanTags() -> Bool {
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let orphans = tags.filter { ($0.thoughts ?? []).isEmpty }
        guard !orphans.isEmpty else { return true }
        for tag in orphans {
            context.delete(tag)
        }
        return persist()
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "store")

    /// Saves, and on failure rolls back so memory matches disk.
    ///
    /// SwiftData crashes ("Could not cast DefaultStoreSnapshotValueFuture to Array<Block>") when
    /// a thought is read after rolling back a failed save that, on a stored thought, did any of:
    /// inserted a Tag linked to it, inserted a Block into it alongside changes to its own fields,
    /// or deleted blocks by cascade or alongside other edits. So `update` saves in steps (new tags,
    /// then field edits and in-place block edits, then block deletions, then block additions) and
    /// deletes children explicitly. A failure part-way leaves consistent data and a retry finishes
    /// the job. Keep any new write on a stored thought within those shapes.
    @discardableResult
    private func persist() -> Bool {
        do {
            try save(context)
            return true
        } catch {
            Self.logger.error("Save failed: \(error)")
            context.rollback()
            saveErrors.report(error)
            return false
        }
    }
}
