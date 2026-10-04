import Foundation
import SwiftData

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

    // MARK: Create & edit

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
        replaceBlocks(of: thought, with: blocks)
        syncTags(for: thought)
        persist()
        return thought
    }

    func update(_ thought: Thought, body: String, blocks: [BlockDraft], intervalDays: Int?, now: Date) {
        let intervalChanged = thought.intervalDays != intervalDays
        thought.body = body
        thought.intervalDays = intervalDays
        if intervalChanged {
            reanchor(thought)
        }
        thought.updatedAt = now
        replaceBlocks(of: thought, with: blocks)
        syncTags(for: thought)
        persist()
    }

    private func replaceBlocks(of thought: Thought, with drafts: [BlockDraft]) {
        for block in thought.blocks ?? [] {
            context.delete(block)
        }
        var blocks: [Block] = []
        for (index, draft) in drafts.enumerated() {
            let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = Block(
                id: draft.id,
                kind: draft.kind,
                content: content,
                title: title.isEmpty ? nil : title,
                order: index
            )
            context.insert(block)
            blocks.append(block)
        }
        thought.blocks = blocks
    }

    /// Rebuilds the thought's tags from its body, creating `Tag`s as needed.
    func syncTags(for thought: Thought) {
        thought.tags = TagParser.parse(thought.body).map(tag(for:))
    }

    private func tag(for parsed: TagParser.ParsedTag) -> Tag {
        let key = parsed.key
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let tag = Tag(name: key, displayName: parsed.display)
        context.insert(tag)
        return tag
    }

    // MARK: Schedule actions

    func markViewed(_ thought: Thought, now: Date) {
        thought.applyView(defaultIntervalDays: defaultIntervalDays, now: now)
        persist()
    }

    func snooze(_ thought: Thought, days: Int, now: Date) {
        thought.applySnooze(days: days, now: now)
        persist()
    }

    func setInterval(_ thought: Thought, days: Int?, now: Date) {
        thought.intervalDays = days
        reanchor(thought)
        thought.updatedAt = now
        persist()
    }

    private func reanchor(_ thought: Thought) {
        thought.nextDueAt = Scheduler.reanchoredDue(
            createdAt: thought.createdAt,
            lastViewedAt: thought.lastViewedAt,
            intervalDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
        )
    }

    func setPinned(_ thought: Thought, _ pinned: Bool) {
        thought.isPinned = pinned
        persist()
    }

    func archive(_ thought: Thought, now: Date) {
        thought.isArchived = true
        thought.isPinned = false
        thought.archivedAt = now
        persist()
    }

    func restore(_ thought: Thought, now: Date) {
        thought.isArchived = false
        thought.archivedAt = nil
        thought.nextDueAt = Scheduler.restoredDue(now: now)
        persist()
    }

    func delete(_ thought: Thought) {
        context.delete(thought)
        persist()
    }

    /// Deletes every thought and tag. One by one, because batch deletes can leave
    /// @Query results stale on iOS 17. Blocks and images go with their thoughts via cascade rules.
    func deleteAll() {
        for thought in (try? context.fetch(FetchDescriptor<Thought>())) ?? [] {
            context.delete(thought)
        }
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] {
            context.delete(tag)
        }
        persist()
    }

    /// Sets schedule fields directly, bypassing the rules. Only for sample data,
    /// which needs thoughts in every state.
    func overrideSchedule(_ thought: Thought, nextDueAt: Date, lastViewedAt: Date?, viewCount: Int) {
        thought.nextDueAt = nextDueAt
        thought.lastViewedAt = lastViewedAt
        thought.viewCount = viewCount
        persist()
    }

    /// Deletes tags that no thought (active or archived) uses any more.
    ///
    /// Call at launch only: a tag timeline on the navigation stack holds its `Tag`, and
    /// reading a deleted model can crash. Until then, empty tags are simply hidden.
    func pruneOrphanTags() {
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let orphans = tags.filter { ($0.thoughts ?? []).isEmpty }
        guard !orphans.isEmpty else { return }
        for tag in orphans {
            context.delete(tag)
        }
        persist()
    }

    private func persist() {
        do {
            try context.save()
        } catch {
            assertionFailure("Save failed: \(error)")
        }
    }
}
