import Foundation
import SwiftData
import os

/// An image the user added in the editor. The id is assigned up front so the editor can insert
/// `ImageToken.token(for:)` into the body immediately.
struct ImageDraft: Identifiable, Equatable {
    let id: UUID
    /// The processed pixels for an image not saved yet; nil for an image already in the store.
    var processed: ProcessedImage?

    init(id: UUID = UUID(), processed: ProcessedImage? = nil) {
        self.id = id
        self.processed = processed
    }

    /// A reference to an image already in the store.
    init(existing image: ImageAsset) {
        self.init(id: image.id)
    }
}

/// Draft of a block being edited, before it is written to the store.
struct BlockDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: BlockKind = .markdown
    var title: String = ""
    var content: String = ""
    /// Markdown blocks only: hidden until tapped.
    var isBlurred = false
    /// Gallery blocks only: the images in display order, new or already stored.
    var images: [ImageDraft] = []
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
    var pendingImageSaves = PendingImageSaves()
    var ratingPrompt = RatingPrompt()
    /// Kept in step after every write that changes searchable text or archive state; see `SearchIndex`.
    var searchIndex: SearchIndex = .shared

    // MARK: Create & edit

    /// `images` are the new inline images; one is saved only if its token is in `body` or a markdown
    /// block's content. Existing inline images are kept while their token stays in either. Gallery
    /// images travel in the gallery's `BlockDraft`.
    ///
    /// If the save fails, the change is rolled back and the returned thought is detached
    /// (`modelContext == nil`). That is how callers tell a save failed; the other writers return a Bool.
    @discardableResult
    func create(
        body: String, blocks: [BlockDraft] = [], images: [ImageDraft] = [], intervalDays: Int? = nil, learn: Bool = false, now: Date
    ) -> Thought {
        let interval = intervalDays ?? defaultIntervalDays
        let thought = Thought(
            body: body,
            createdAt: now,
            nextDueAt: learn ? Scheduler.learnStartDue(now: now) : Scheduler.firstDue(createdAt: now, intervalDays: interval),
            intervalDays: intervalDays
        )
        if learn { thought.intervalMode = .learn }
        context.insert(thought)
        let plan = plan(for: thought, body: body, blocks: blocks, images: images)
        let tagsSynced = syncTags(for: thought, texts: plan.texts)
        insertNewBlocks(of: plan, into: thought, firstOrder: 0)
        insertNewInlineImages(of: plan, into: thought)
        removeStaleInlineImages(of: plan)
        if persist(requiring: tagsSynced) {
            indexUpsert(thought)
        }
        return thought
    }

    /// Edits the thought to match the drafts. Saves in steps; see `persist()`.
    @discardableResult
    func update(
        _ thought: Thought, body: String, blocks: [BlockDraft], images: [ImageDraft] = [], intervalDays: Int?, now: Date
    ) -> Bool {
        // Whatever step failed, the index gets the thought as it now is.
        defer { reindex(ids: [thought.id]) }
        return performUpdate(thought, body: body, blocks: blocks, images: images, intervalDays: intervalDays, now: now)
    }

    private func performUpdate(
        _ thought: Thought, body: String, blocks: [BlockDraft], images: [ImageDraft], intervalDays: Int?, now: Date
    ) -> Bool {
        if pendingImageSaves.ids.contains(thought.id), !removeTokenlessInlineImages(of: thought) {
            return false
        }
        let plan = plan(for: thought, body: body, blocks: blocks, images: images)
        guard saveNewTags(for: plan.texts) else { return false }
        let addedInline = insertNewInlineImages(of: plan, into: thought)
        let hasPendingImages = !addedInline.isEmpty
        if hasPendingImages {
            pendingImageSaves.insert(thought.id)
            guard persist() else {
                pendingImageSaves.remove(thought.id)
                return false
            }
        }
        let intervalChanged = thought.intervalDays != intervalDays
        thought.body = body
        thought.intervalDays = intervalDays
        if intervalChanged, thought.intervalMode != .learn {
            reanchor(thought)
        }
        thought.updatedAt = now
        let editTagsSynced = syncTags(for: thought, texts: plan.textsWhileSurplusRemains)
        editKeptBlocks(of: plan)
        removeStaleInlineImages(of: plan)
        guard persist(requiring: editTagsSynced) else {
            if discardAfterFailure(addedInline) {
                pendingImageSaves.remove(thought.id)
            }
            return false
        }
        if hasPendingImages {
            pendingImageSaves.remove(thought.id)
        }

        removeStale(plan)
        let keptTagsSynced = syncTags(for: thought, texts: plan.keptTexts)
        if context.hasChanges || !keptTagsSynced {
            guard persist(requiring: keptTagsSynced) else { return false }
        }
        insertNewBlocks(of: plan, into: thought, firstOrder: plan.blocks.filter { $0.existing != nil }.count)
        let finalTagsSynced = syncTags(for: thought, texts: plan.texts)
        if context.hasChanges || !finalTagsSynced {
            guard persist(requiring: finalTagsSynced) else { return false }
        }
        applyFinalOrders(of: plan, in: thought)
        return !context.hasChanges || persist()
    }

    private struct PlannedBlock {
        let id: UUID
        let kind: BlockKind
        let title: String?
        let content: String
        var isBlurred = false
        /// Gallery blocks: the images wanted, in display order.
        var images: [ImageDraft] = []
        var existing: Block?
    }

    private struct Plan {
        var blocks: [PlannedBlock] = []
        var surplusBlocks: [Block] = []
        var staleGalleryImages: [ImageAsset] = []
        /// Inline images no longer referenced by the body, a kept block or a block about to be
        /// removed; deleted with the body edit.
        var staleInlineImages: [ImageAsset] = []
        /// Inline images whose only remaining reference is a block about to be removed; deleted with it.
        var staleInlineImagesOfSurplusBlocks: [ImageAsset] = []
        /// New inline images referenced by the body or a kept block; saved before the body edit.
        var newInlineImages: [ImageDraft] = []
        /// New inline images referenced only by new blocks; saved with those blocks so no image is
        /// ever stored without a token.
        var newInlineImagesOfNewBlocks: [ImageDraft] = []

        /// The body and every markdown block's content, as they will be once the plan is applied.
        var texts: [String] = []
        /// The texts stored after the body edit, before surplus blocks are removed and new ones added.
        var textsWhileSurplusRemains: [String] = []
        /// The texts stored once surplus blocks are removed, before new ones are added.
        var keptTexts: [String] = []
    }

    /// Works out what the drafts mean for the thought's current blocks and images, without
    /// changing anything: which blocks to edit in place, delete or add (blank markdown blocks and
    /// empty galleries are dropped), and which images to delete or add. Markdown drafts reuse the
    /// existing markdown blocks by position; a gallery draft matches the existing gallery with its id.
    /// An inline image is kept while its token is in the body or any markdown block.
    ///
    /// Ids stay unique: a draft block repeating an earlier draft's id is dropped, a draft image
    /// whose id is already taken is skipped, and a new block colliding with an existing block's id
    /// gets a fresh one. An existing image listed under a different gallery than the one holding it
    /// is not moved; it stays at the end of its own gallery, which survives even if its own draft
    /// is empty.
    private func plan(for thought: Thought, body: String, blocks drafts: [BlockDraft], images inline: [ImageDraft]) -> Plan {
        var plan = Plan()
        var reusableMarkdown = thought.sortedBlocks.filter { $0.kind == .markdown }[...]
        var reusableGalleries = Dictionary(
            (thought.blocks ?? []).filter { $0.kind == .gallery }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingBlockIDs = Set((thought.blocks ?? []).map(\.id))
        var claimedBlockIDs = Set<UUID>()
        let storedImageIDs = Set((thought.images ?? []).map(\.id))
        let listedElsewhere = Set(drafts.filter { $0.kind == .gallery }.flatMap(\.images).filter { $0.processed == nil }.map(\.id))
        var claimedImageIDs = Set<UUID>()

        for draft in drafts where claimedBlockIDs.insert(draft.id).inserted {
            let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? nil : trimmedTitle
            switch draft.kind {
            case .markdown:
                let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let reused = reusableMarkdown.popFirst()
                let id = reused?.id == draft.id || !existingBlockIDs.contains(draft.id) ? draft.id : UUID()
                plan.blocks.append(PlannedBlock(
                    id: id, kind: .markdown, title: title, content: content, isBlurred: draft.isBlurred, existing: reused
                ))
            case .gallery:
                let existing = reusableGalleries[draft.id]
                let stored = Dictionary(
                    (existing?.images ?? []).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                var wanted = draft.images.filter { image in
                    let usable = stored[image.id] != nil || (image.processed != nil && !storedImageIDs.contains(image.id))
                    return usable && claimedImageIDs.insert(image.id).inserted
                }
                var dropped: [ImageAsset] = []
                for image in (existing?.sortedImages ?? []) where !claimedImageIDs.contains(image.id) {
                    if listedElsewhere.contains(image.id) {
                        claimedImageIDs.insert(image.id)
                        wanted.append(ImageDraft(existing: image))
                    } else {
                        dropped.append(image)
                    }
                }
                guard !wanted.isEmpty else { continue }
                plan.staleGalleryImages += dropped
                reusableGalleries[draft.id] = nil
                let id = existing != nil || !existingBlockIDs.contains(draft.id) ? draft.id : UUID()
                plan.blocks.append(PlannedBlock(id: id, kind: .gallery, title: title, content: "", images: wanted, existing: existing))
            }
        }
        plan.surplusBlocks = Array(reusableMarkdown) + Array(reusableGalleries.values)

        let markdown = plan.blocks.filter { $0.kind == .markdown }
        plan.texts = [body] + markdown.map(\.content)
        plan.keptTexts = [body] + markdown.filter { $0.existing != nil }.map(\.content)
        plan.textsWhileSurplusRemains = plan.keptTexts + reusableMarkdown.map(\.content)
        func tokens(in texts: [String]) -> Set<UUID> {
            Set(texts.flatMap { ImageToken.references(in: $0) })
        }
        let earlyTokens = tokens(in: [body] + markdown.filter { $0.existing != nil }.map(\.content))
        let newBlockTokens = tokens(in: markdown.filter { $0.existing == nil }.map(\.content))
        let surplusTokens = tokens(in: reusableMarkdown.map(\.content))
        let wanted = earlyTokens.union(newBlockTokens)
        for image in thought.images ?? [] where image.block == nil && !wanted.contains(image.id) {
            if surplusTokens.contains(image.id) {
                plan.staleInlineImagesOfSurplusBlocks.append(image)
            } else {
                plan.staleInlineImages.append(image)
            }
        }
        for draft in inline where draft.processed != nil && wanted.contains(draft.id) && !storedImageIDs.contains(draft.id) {
            guard claimedImageIDs.insert(draft.id).inserted else { continue }
            if earlyTokens.contains(draft.id) {
                plan.newInlineImages.append(draft)
            } else {
                plan.newInlineImagesOfNewBlocks.append(draft)
            }
        }
        return plan
    }

    private func editKeptBlocks(of plan: Plan) {
        for planned in plan.blocks {
            guard let block = planned.existing else { continue }
            block.id = planned.id
            block.title = planned.title
            block.content = planned.content
            block.isBlurred = planned.isBlurred
        }
    }

    /// Deletes stale images and surplus blocks (with their images) explicitly, then renumbers the
    /// survivors so orders stay contiguous.
    private func removeStale(_ plan: Plan) {
        for image in plan.staleGalleryImages + plan.staleInlineImagesOfSurplusBlocks {
            remove(image)
        }
        for block in plan.surplusBlocks {
            for image in block.images ?? [] {
                remove(image)
            }
            block.thought = nil
            context.delete(block)
        }
        let kept = plan.blocks.compactMap(\.existing).sorted { $0.order < $1.order }
        for (index, block) in kept.enumerated() {
            setOrder(of: block, to: index)
            for (position, image) in block.sortedImages.enumerated() {
                setOrder(of: image, to: position)
            }
        }
    }

    /// Adds the blocks that are new (ordered from `firstOrder`), the new images of kept galleries,
    /// after the images already there, and the inline images only the new blocks reference.
    private func insertNewBlocks(of plan: Plan, into thought: Thought, firstOrder: Int) {
        for draft in plan.newInlineImagesOfNewBlocks {
            insertImage(draft, order: 0, into: thought, block: nil)
        }
        var order = firstOrder
        for planned in plan.blocks {
            if let block = planned.existing {
                var position = block.images?.count ?? 0
                for draft in planned.images where !(block.images ?? []).contains(where: { $0.id == draft.id }) {
                    insertImage(draft, order: position, into: thought, block: block)
                    position += 1
                }
            } else {
                let block = Block(
                    id: planned.id, kind: planned.kind, content: planned.content, title: planned.title,
                    isBlurred: planned.isBlurred, order: order
                )
                order += 1
                context.insert(block)
                block.thought = thought
                for (position, draft) in planned.images.enumerated() {
                    insertImage(draft, order: position, into: thought, block: block)
                }
            }
        }
    }

    /// Removed in the same save as the body edit that drops their tokens.
    private func removeStaleInlineImages(of plan: Plan) {
        for image in plan.staleInlineImages {
            remove(image)
        }
    }

    /// `update` saves these before the body edit: inserting an image into a stored thought alongside
    /// edits to its fields crashes after a rollback.
    @discardableResult
    private func insertNewInlineImages(of plan: Plan, into thought: Thought) -> [ImageAsset] {
        plan.newInlineImages.compactMap { insertImage($0, order: 0, into: thought, block: nil) }
    }

    /// Takes back images saved ahead of a body edit that then failed, so none is left without its
    /// token. Returns false if that save failed too; the thought then stays in `pendingImageSaves`.
    private func discardAfterFailure(_ images: [ImageAsset]) -> Bool {
        for image in images {
            remove(image)
        }
        return persist()
    }

    /// Run at launch. For each thought left in `pendingImageSaves`, deletes inline images whose
    /// token is not in the body, and clears the marker only once that is saved. Does nothing, and
    /// reads nothing from the store, when no thought is marked.
    @discardableResult
    func cleanUpPendingImageSaves() -> Bool {
        var allSucceeded = true
        for id in pendingImageSaves.ids {
            var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let found: [Thought]
            do {
                found = try context.fetch(descriptor)
            } catch {
                Self.logger.error("Pending image cleanup fetch failed: \(error)")
                allSucceeded = false
                continue
            }
            guard let thought = found.first else {
                pendingImageSaves.remove(id)
                continue
            }
            if !removeTokenlessInlineImages(of: thought) {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Run at launch. Turns blocks stored with the old "blurred" kind into blurred markdown blocks.
    /// Reads nothing but those blocks, so it is cheap once none are left.
    @discardableResult
    func migrateLegacyBlurredBlocks() -> Bool {
        let legacy = BlockKind.legacyBlurredRaw
        let found: [Block]
        do {
            found = try context.fetch(FetchDescriptor<Block>(predicate: #Predicate { $0.kindRaw == legacy }))
        } catch {
            Self.logger.error("Legacy block fetch failed: \(error)")
            return false
        }
        guard !found.isEmpty else { return true }
        for block in found {
            block.kindRaw = BlockKind.markdown.rawValue
            block.isBlurred = true
        }
        return persist()
    }

    /// Deletes the thought's inline images whose token is not in its body or a markdown block and,
    /// once that is saved, clears its marker. `update` runs this first on a marked thought: editing a thought
    /// that still holds such images crashes after a later rollback.
    private func removeTokenlessInlineImages(of thought: Thought) -> Bool {
        let tokens = Set(thought.inlineImageReferences)
        let orphans = (thought.images ?? []).filter { $0.block == nil && !tokens.contains($0.id) }
        for image in orphans {
            remove(image)
        }
        if !orphans.isEmpty, !persist() {
            return false
        }
        pendingImageSaves.remove(thought.id)
        return true
    }

    @discardableResult
    private func insertImage(_ draft: ImageDraft, order: Int, into thought: Thought, block: Block?) -> ImageAsset? {
        guard let processed = draft.processed else { return nil }
        let image = ImageAsset(
            id: draft.id, data: processed.data, thumbnailData: processed.thumbnailData,
            width: processed.width, height: processed.height, order: order
        )
        context.insert(image)
        image.thought = thought
        image.block = block
        return image
    }

    private func remove(_ image: ImageAsset) {
        image.thought = nil
        image.block = nil
        context.delete(image)
    }

    /// Puts blocks and gallery images in their drafted order.
    private func applyFinalOrders(of plan: Plan, in thought: Thought) {
        let blocks = Dictionary((thought.blocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, planned) in plan.blocks.enumerated() {
            guard let block = blocks[planned.id] else { continue }
            setOrder(of: block, to: index)
            let images = Dictionary((block.images ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (position, draft) in planned.images.enumerated() {
                if let image = images[draft.id] {
                    setOrder(of: image, to: position)
                }
            }
        }
    }

    private func setOrder(of block: Block, to order: Int) {
        if block.order != order { block.order = order }
    }

    private func setOrder(of image: ImageAsset, to order: Int) {
        if image.order != order { image.order = order }
    }

    /// Rebuilds the thought's tags from its body and markdown blocks, creating `Tag`s as needed.
    @discardableResult
    func syncTags(for thought: Thought) -> Bool {
        syncTags(for: thought, texts: thought.markdownTexts)
    }

    /// False if a tag lookup failed (logged and reported); the caller then rolls back with `persist(requiring: false)`.
    @discardableResult
    private func syncTags(for thought: Thought, texts: [String]) -> Bool {
        do {
            let wanted = try TagParser.parse(all: texts).map(tag(for:))
            let wantedNames = Set(wanted.map(\.name))
            thought.tags?.removeAll { !wantedNames.contains($0.name) }
            let existing = Set((thought.tags ?? []).map(\.name))
            for tag in wanted where !existing.contains(tag.name) {
                thought.tags?.append(tag)
            }
            return true
        } catch {
            Self.logger.error("Tag lookup failed: \(error)")
            saveErrors.report(error)
            return false
        }
    }

    /// Saves tags the texts need that don't exist yet, before the thought is edited; see `persist()`.
    private func saveNewTags(for texts: [String]) -> Bool {
        var inserted = false
        do {
            for parsed in TagParser.parse(all: texts) where try existingTag(named: parsed.key) == nil {
                context.insert(Tag(name: parsed.key, displayName: parsed.display))
                inserted = true
            }
        } catch {
            Self.logger.error("Tag lookup failed: \(error)")
            context.rollback()
            saveErrors.report(error)
            return false
        }
        return !inserted || persist()
    }

    /// Throws on a fetch error rather than answering "no tag", which would create a duplicate.
    private func existingTag(named key: String) throws -> Tag? {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func tag(for parsed: TagParser.ParsedTag) throws -> Tag {
        if let existing = try existingTag(named: parsed.key) {
            return existing
        }
        let tag = Tag(name: parsed.key, displayName: parsed.display)
        context.insert(tag)
        return tag
    }

    // MARK: Schedule actions

    @discardableResult
    func markViewed(_ thought: Thought, now: Date) -> Bool {
        let countsAsDueOpen = thought.intervalMode != .learn && Scheduler.countsAsDueOpen(
            isPinned: thought.isPinned,
            isArchived: thought.isArchived,
            nextDueAt: thought.nextDueAt,
            now: now
        )
        thought.applyView(defaultIntervalDays: defaultIntervalDays, now: now)
        guard persist() else { return false }
        if countsAsDueOpen { ratingPrompt.recordDueOpen() }
        return true
    }

    @discardableResult
    func snooze(_ thought: Thought, days: Int, now: Date) -> Bool {
        thought.applySnooze(days: days, now: now)
        return persist()
    }

    @discardableResult
    func setInterval(_ thought: Thought, days: Int?, now: Date) -> Bool {
        thought.intervalDays = days
        if thought.intervalMode != .learn { reanchor(thought) }
        thought.updatedAt = now
        defer { indexFingerprint(of: thought) }
        return persist()
    }

    /// Turning on makes the first review tomorrow; turning off goes back to the fixed interval.
    /// An edit, so it bumps `updatedAt`.
    @discardableResult
    func setLearnMode(_ thought: Thought, _ enabled: Bool, now: Date) -> Bool {
        guard (thought.intervalMode == .learn) != enabled else { return true }
        thought.learnIntervalDays = nil
        if enabled {
            thought.intervalMode = .learn
            thought.nextDueAt = Scheduler.learnStartDue(now: now)
        } else {
            thought.intervalMode = .fixed
            reanchor(thought)
        }
        thought.updatedAt = now
        defer { indexFingerprint(of: thought) }
        return persist()
    }

    /// Rates a Learn thought that is due, unpinned and not archived; otherwise writes nothing and returns
    /// false. Not a view or an edit: `updatedAt`, `lastViewedAt` and `viewCount` stay.
    @discardableResult
    func review(_ thought: Thought, gotIt: Bool, now: Date) -> Bool {
        guard thought.intervalMode == .learn, !thought.isPinned, !thought.isArchived, thought.isDue(now: now) else { return false }
        let result = Scheduler.afterReview(
            gotIt: gotIt,
            lastGapDays: thought.learnIntervalDays,
            baseIntervalDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays),
            now: now
        )
        thought.nextDueAt = result.nextDueAt
        thought.learnIntervalDays = result.learnIntervalDays
        guard persist() else { return false }
        ratingPrompt.recordDueOpen()
        return true
    }

    private func reanchor(_ thought: Thought) {
        thought.nextDueAt = Scheduler.reanchoredDue(
            createdAt: thought.createdAt,
            lastViewedAt: thought.lastViewedAt,
            intervalDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
        )
    }

    /// `nil` restores the automatic color. Invalid hex is rejected without writing.
    @discardableResult
    func setColor(_ tag: Tag, hex: String?) -> Bool {
        var normalized: String?
        if let hex {
            guard let valid = TagColor.normalizedHex(hex) else { return false }
            normalized = valid
        }
        guard tag.colorHex != normalized else { return true }
        tag.colorHex = normalized
        return persist()
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
        defer { indexFingerprint(of: thought) }
        return persist()
    }

    @discardableResult
    func restore(_ thought: Thought, now: Date) -> Bool {
        thought.isArchived = false
        thought.archivedAt = nil
        thought.nextDueAt = Scheduler.restoredDue(now: now)
        defer { indexFingerprint(of: thought) }
        return persist()
    }

    @discardableResult
    func delete(_ thought: Thought) -> Bool {
        let id = thought.id
        deleteWithChildren(thought)
        defer { reindex(ids: [id]) }
        return persist()
    }

    /// Deletes blocks and images explicitly rather than by cascade; see `persist()`.
    private func deleteWithChildren(_ thought: Thought) {
        for block in thought.blocks ?? [] {
            for image in block.images ?? [] {
                remove(image)
            }
            block.thought = nil
            context.delete(block)
        }
        for image in thought.images ?? [] {
            remove(image)
        }
        context.delete(thought)
    }

    /// Deletes every thought and tag, one by one through `deleteWithChildren` so each thought's
    /// blocks and images are removed explicitly as the `persist()` note requires. A failed fetch
    /// deletes nothing and returns false.
    @discardableResult
    func deleteAll() -> Bool {
        let thoughts: [Thought]
        let tags: [Tag]
        do {
            thoughts = try context.fetch(FetchDescriptor<Thought>())
            tags = try context.fetch(FetchDescriptor<Tag>())
        } catch {
            Self.logger.error("Delete all fetch failed: \(error)")
            saveErrors.report(error)
            return false
        }
        for thought in thoughts {
            deleteWithChildren(thought)
        }
        for tag in tags {
            context.delete(tag)
        }
        guard persist() else { return false }
        searchIndex.submit(.removeAll)
        return true
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
        let tags: [Tag]
        do {
            tags = try context.fetch(FetchDescriptor<Tag>())
        } catch {
            Self.logger.error("Orphan tag lookup failed: \(error)")
            return false
        }
        let orphans: [Tag]
        do {
            orphans = try tags.filter { tag in
                var descriptor = FetchDescriptor<Thought>(predicate: ThoughtCounts.any(tag: tag.name))
                descriptor.fetchLimit = 1
                return try context.fetchCount(descriptor) == 0
            }
        } catch {
            Self.logger.error("Orphan tag count failed: \(error)")
            return false
        }
        guard !orphans.isEmpty else { return true }
        for tag in orphans {
            context.delete(tag)
        }
        return persist()
    }

    // MARK: Import

    /// Merges a batch read from an export, by thought id: unknown ids are added, a stored thought
    /// with an older `updatedAt` is replaced wholesale (blocks and images too), and an equal or
    /// newer stored one is left alone, so importing the same file twice changes nothing.
    ///
    /// Added thoughts land in one save. A replacement goes through `update` (so it follows the
    /// `persist()` note: new tags are saved first, children are saved in steps) and then writes the
    /// remaining fields and `updatedAt` last; a failure part-way leaves consistent data, the thought
    /// still looks older than the file, and importing again finishes it. Returns false on the first
    /// failure with `tally` counting what was written before it. `tags` give the display name and
    /// color of tags that don't exist yet.
    @discardableResult
    func importThoughts(_ batch: [ImportedThought], tags tagInfo: [TagRecord], tally: inout ImportTally) -> Bool {
        defer { reindex(ids: Set(batch.map(\.record.id))) }
        return performImport(batch, tags: tagInfo, tally: &tally)
    }

    private func performImport(_ batch: [ImportedThought], tags tagInfo: [TagRecord], tally: inout ImportTally) -> Bool {
        var newest: [UUID: ImportedThought] = [:]
        var ids: [UUID] = []
        for item in batch {
            let id = item.record.id
            if let kept = newest[id] {
                tally.upToDate += 1
                if item.record.updatedAt > kept.record.updatedAt { newest[id] = item }
            } else {
                newest[id] = item
                ids.append(id)
            }
        }
        let items = ids.compactMap { newest[$0] }

        let stored: [UUID: Thought]
        var imageOwners: [UUID: UUID?] = [:]
        var takenBlockIDs = Set<UUID>()
        do {
            let lookup = ids
            stored = Dictionary(
                try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { lookup.contains($0.id) })).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let imageIDs = items.flatMap(\.record.imageIDs)
            for image in try context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { imageIDs.contains($0.id) })) {
                imageOwners[image.id] = image.thought?.id
            }
            let blockIDs = items.flatMap { $0.record.blocks.map(\.id) }
            takenBlockIDs = Set(try context.fetch(FetchDescriptor<Block>(predicate: #Predicate { blockIDs.contains($0.id) })).map(\.id))
        } catch {
            Self.logger.error("Import lookup failed: \(error)")
            saveErrors.report(error)
            return false
        }

        var additions: [ImportedThought] = []
        var replacements: [(thought: Thought, item: ImportedThought)] = []
        var claimedImageIDs = Set<UUID>()
        for item in items {
            let record = item.record
            let imageClash = record.imageIDs.contains { imageID in
                claimedImageIDs.contains(imageID) || imageOwners[imageID].map { $0 != record.id } ?? false
            }
            if imageClash {
                tally.rejected += 1
            } else if let current = stored[record.id] {
                if record.updatedAt > current.updatedAt {
                    claimedImageIDs.formUnion(record.imageIDs)
                    replacements.append((current, item))
                } else {
                    tally.upToDate += 1
                }
            } else {
                claimedImageIDs.formUnion(record.imageIDs)
                additions.append(item)
            }
        }

        guard let tagsByName = saveTags(for: additions + replacements.map(\.item), info: tagInfo) else { return false }

        if !additions.isEmpty {
            for item in additions {
                insertImported(item, tags: tagsByName, takenBlockIDs: &takenBlockIDs)
            }
            guard persist() else { return false }
            tally.added += additions.count
        }
        for (thought, item) in replacements {
            guard replace(thought, with: item, takenBlockIDs: &takenBlockIDs) else { return false }
            tally.replaced += 1
        }
        return true
    }

    /// Saves the tags the bodies need that don't exist yet, before any thought links to them.
    private func saveTags(for items: [ImportedThought], info: [TagRecord]) -> [String: Tag]? {
        let parsed = TagParser.parse(all: items.flatMap { $0.record.markdownTexts })
        let names = Set(parsed.map(\.key))
        guard !names.isEmpty else { return [:] }
        var byName: [String: Tag]
        do {
            byName = Dictionary(
                try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { names.contains($0.name) })).map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            Self.logger.error("Import tag lookup failed: \(error)")
            saveErrors.report(error)
            return nil
        }
        let known = Dictionary(info.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted = false
        for tag in parsed where byName[tag.key] == nil {
            let created = Tag(name: tag.key, displayName: known[tag.key]?.displayName ?? tag.display)
            created.colorHex = known[tag.key]?.colorHex.flatMap(TagColor.normalizedHex)
            context.insert(created)
            byName[tag.key] = created
            inserted = true
        }
        return !inserted || persist() ? byName : nil
    }

    private func insertImported(_ item: ImportedThought, tags: [String: Tag], takenBlockIDs: inout Set<UUID>) {
        let record = item.record
        let thought = Thought(body: record.body, createdAt: record.createdAt, nextDueAt: record.nextDueAt)
        thought.id = record.id
        apply(record, to: thought)
        context.insert(thought)
        thought.tags = TagParser.parse(all: record.markdownTexts).compactMap { tags[$0.key] }

        let tokens = Set(record.inlineImageReferences)
        for ref in record.images where tokens.contains(ref.id) {
            insertImported(ref, from: item, order: 0, into: thought, block: nil)
        }
        let blocks = record.blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
        for (order, entry) in blocks.enumerated() {
            let source = entry.element
            let id = takenBlockIDs.contains(source.id) ? UUID() : source.id
            takenBlockIDs.insert(id)
            let resolved = source.resolved ?? (kind: .markdown, isBlurred: false)
            let block = Block(
                id: id, kind: resolved.kind, content: source.content, title: source.title, isBlurred: resolved.isBlurred, order: order
            )
            context.insert(block)
            block.thought = thought
            let images = source.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            for (position, image) in images.enumerated() {
                insertImported(image.element, from: item, order: position, into: thought, block: block)
            }
        }
    }

    private func insertImported(_ ref: ImageRecord, from item: ImportedThought, order: Int, into thought: Thought, block: Block?) {
        guard let processed = item.images[ref.id] else { return }
        let image = ImageAsset(
            id: ref.id, data: processed.data, thumbnailData: processed.thumbnailData,
            width: processed.width, height: processed.height, order: order
        )
        context.insert(image)
        image.thought = thought
        image.block = block
    }

    private func replace(_ thought: Thought, with item: ImportedThought, takenBlockIDs: inout Set<UUID>) -> Bool {
        let record = item.record
        let ownBlockIDs = Set((thought.blocks ?? []).map(\.id))
        var claimed = takenBlockIDs
        func blockID(_ id: UUID) -> UUID {
            let fresh = claimed.contains(id) && !ownBlockIDs.contains(id) ? UUID() : id
            claimed.insert(fresh)
            return fresh
        }
        func draft(_ ref: ImageRecord) -> ImageDraft {
            ImageDraft(id: ref.id, processed: item.images[ref.id])
        }
        let blocks = record.blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { entry in
            let block = entry.element
            let resolved = block.resolved ?? (kind: .markdown, isBlurred: false)
            return BlockDraft(
                id: blockID(block.id), kind: resolved.kind, title: block.title ?? "", content: block.content, isBlurred: resolved.isBlurred,
                images: block.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { draft($0.element) }
            )
        }
        // The index fingerprint is `updatedAt` plus the archive flag. If the app dies mid-replace, `updatedAt`
        // is unchanged until the last save, so reconciliation can miss the stale text until the thought is next edited.
        // `update` leaves `updatedAt` as it is, so the thought keeps looking older than the file until the last save.
        guard performUpdate(thought, body: record.body, blocks: blocks, images: record.images.map(draft), intervalDays: record.intervalDays, now: thought.updatedAt)
        else { return false }
        takenBlockIDs = claimed
        apply(record, to: thought)
        return persist()
    }

    private func apply(_ record: ThoughtRecord, to thought: Thought) {
        thought.createdAt = record.createdAt
        thought.nextDueAt = record.nextDueAt
        thought.lastViewedAt = record.lastViewedAt
        thought.viewCount = record.viewCount
        thought.intervalDays = record.intervalDays
        thought.intervalModeRaw = record.intervalModeRaw
        thought.learnIntervalDays = record.learnIntervalDays
        thought.isPinned = record.isPinned
        thought.isArchived = record.isArchived
        thought.archivedAt = record.archivedAt
        thought.updatedAt = record.updatedAt
    }

    // MARK: Search index

    // Any new writer that changes the body, block content or titles, or tag names must reindex the
    // thought (`reindex(ids:)`), or search results go stale until the next launch's reconciliation.

    private func indexUpsert(_ thought: Thought) {
        searchIndex.submit(.upsert(SearchDocument(thought)))
    }

    private func indexFingerprint(of thought: Thought) {
        searchIndex.submit(.setFingerprint(thought.id, updatedAt: thought.updatedAt, isArchived: thought.isArchived))
    }

    /// Sends the index the thoughts as the store now has them, and drops the ids it no longer has.
    ///
    /// The thoughts are fetched rather than read from the objects the caller holds: after a failed
    /// save is rolled back, reading a relationship such as `tags` straight off such an object can
    /// crash SwiftData (see `persist()`), while a fresh fetch is safe.
    private func reindex(ids: Set<UUID>) {
        let lookup = Array(ids)
        do {
            var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { lookup.contains($0.id) })
            descriptor.relationshipKeyPathsForPrefetching = [\.blocks, \.tags]
            let found = try context.fetch(descriptor)
            for thought in found {
                indexUpsert(thought)
            }
            for id in ids.subtracting(found.map(\.id)) {
                searchIndex.submit(.remove(id))
            }
        } catch {
            Self.logger.error("Search reindex fetch failed: \(error)")
        }
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "store")

    /// Saves, and on failure rolls back so memory matches disk.
    ///
    /// SwiftData crashes ("Could not cast DefaultStoreSnapshotValueFuture to Array<Block>", or
    /// `Array<ImageAsset>`) when a model is read after rolling back a failed save that, on a stored
    /// thought, did any of: inserted a Tag linked to it, inserted a Block or an ImageAsset into it
    /// alongside changes to its own fields, deleted blocks by cascade or alongside other edits, or
    /// deleted a block whose `images` had not been read yet. So `update` saves in steps (new tags;
    /// new inline images; field edits, in-place block edits and removal of inline images, which
    /// land together so the body and its images agree; deletions; additions; final ordering) and
    /// deletes children explicitly. A failure part-way leaves consistent data and a retry finishes
    /// the job. The one exception: new inline images are saved before the body edit, so `update`
    /// marks the thought in `pendingImageSaves` first and clears it when the edit saves or the
    /// images are taken back; if both saves fail, or the app dies between them, the marker stays
    /// and `cleanUpPendingImageSaves` (at launch) deletes the token-less images. `update` also
    /// does that first for a marked thought (stacking failed saves on a thought that still holds
    /// them crashes), and refuses to edit it if that fails. Keep any new write on a stored
    /// thought within those shapes.
    @discardableResult
    private func persist(requiring ok: Bool = true) -> Bool {
        guard ok else {
            context.rollback()
            return false
        }
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
