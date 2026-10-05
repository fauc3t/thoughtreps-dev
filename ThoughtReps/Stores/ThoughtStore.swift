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
    var kind: BlockKind = .blurred
    var title: String = ""
    var content: String = ""
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

    // MARK: Create & edit

    /// `images` are the new inline images; one is saved only if its token is in `body`. Existing
    /// inline images are kept while their token stays in the body. Gallery images travel in the
    /// gallery's `BlockDraft`.
    ///
    /// If the save fails, the change is rolled back and the returned thought is detached
    /// (`modelContext == nil`). That is how callers tell a save failed; the other writers return a Bool.
    @discardableResult
    func create(
        body: String, blocks: [BlockDraft] = [], images: [ImageDraft] = [], intervalDays: Int? = nil, now: Date
    ) -> Thought {
        let interval = intervalDays ?? defaultIntervalDays
        let thought = Thought(
            body: body,
            createdAt: now,
            nextDueAt: Scheduler.firstDue(createdAt: now, intervalDays: interval),
            intervalDays: intervalDays
        )
        context.insert(thought)
        syncTags(for: thought)
        let plan = plan(for: thought, body: body, blocks: blocks, images: images)
        insertNewBlocks(of: plan, into: thought, firstOrder: 0)
        insertNewInlineImages(of: plan, into: thought)
        removeStaleInlineImages(of: plan)
        persist()
        return thought
    }

    /// Edits the thought to match the drafts. Saves in steps; see `persist()`.
    @discardableResult
    func update(
        _ thought: Thought, body: String, blocks: [BlockDraft], images: [ImageDraft] = [], intervalDays: Int?, now: Date
    ) -> Bool {
        if pendingImageSaves.ids.contains(thought.id), !removeTokenlessInlineImages(of: thought) {
            return false
        }
        guard saveNewTags(for: body) else { return false }
        let plan = plan(for: thought, body: body, blocks: blocks, images: images)
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
        if intervalChanged {
            reanchor(thought)
        }
        thought.updatedAt = now
        syncTags(for: thought)
        editKeptBlocks(of: plan)
        removeStaleInlineImages(of: plan)
        guard persist() else {
            if discardAfterFailure(addedInline) {
                pendingImageSaves.remove(thought.id)
            }
            return false
        }
        if hasPendingImages {
            pendingImageSaves.remove(thought.id)
        }

        removeStale(plan)
        if context.hasChanges {
            guard persist() else { return false }
        }
        insertNewBlocks(of: plan, into: thought, firstOrder: plan.blocks.filter { $0.existing != nil }.count)
        if context.hasChanges {
            guard persist() else { return false }
        }
        applyFinalOrders(of: plan, in: thought)
        return !context.hasChanges || persist()
    }

    private struct PlannedBlock {
        let id: UUID
        let kind: BlockKind
        let title: String?
        let content: String
        /// Gallery blocks: the images wanted, in display order.
        var images: [ImageDraft] = []
        var existing: Block?
    }

    private struct Plan {
        var blocks: [PlannedBlock] = []
        var surplusBlocks: [Block] = []
        var staleGalleryImages: [ImageAsset] = []
        var staleInlineImages: [ImageAsset] = []
        var newInlineImages: [ImageDraft] = []
    }

    /// Works out what the drafts mean for the thought's current blocks and images, without
    /// changing anything: which blocks to edit in place, delete or add (blank blurred blocks and
    /// empty galleries are dropped), and which images to delete or add. Blurred drafts reuse the
    /// existing blurred blocks by position; a gallery draft matches the existing gallery with its id.
    ///
    /// Ids stay unique: a draft block repeating an earlier draft's id is dropped, a draft image
    /// whose id is already taken is skipped, and a new block colliding with an existing block's id
    /// gets a fresh one. An existing image listed under a different gallery than the one holding it
    /// is not moved; it stays at the end of its own gallery, which survives even if its own draft
    /// is empty.
    private func plan(for thought: Thought, body: String, blocks drafts: [BlockDraft], images inline: [ImageDraft]) -> Plan {
        var plan = Plan()
        var reusableBlurred = thought.sortedBlocks.filter { $0.kind == .blurred }[...]
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
            case .blurred:
                let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let reused = reusableBlurred.popFirst()
                let id = reused?.id == draft.id || !existingBlockIDs.contains(draft.id) ? draft.id : UUID()
                plan.blocks.append(PlannedBlock(id: id, kind: .blurred, title: title, content: content, existing: reused))
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
        plan.surplusBlocks = Array(reusableBlurred) + Array(reusableGalleries.values)

        let tokens = Set(ImageToken.references(in: body))
        plan.staleInlineImages = (thought.images ?? []).filter { $0.block == nil && !tokens.contains($0.id) }
        plan.newInlineImages = inline.filter {
            $0.processed != nil && tokens.contains($0.id) && !storedImageIDs.contains($0.id) && claimedImageIDs.insert($0.id).inserted
        }
        return plan
    }

    private func editKeptBlocks(of plan: Plan) {
        for planned in plan.blocks {
            guard let block = planned.existing else { continue }
            block.id = planned.id
            block.title = planned.title
            block.content = planned.content
        }
    }

    /// Deletes stale images and surplus blocks (with their images) explicitly, then renumbers the
    /// survivors so orders stay contiguous.
    private func removeStale(_ plan: Plan) {
        for image in plan.staleGalleryImages {
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

    /// Adds the blocks that are new (ordered from `firstOrder`) and the new images of kept galleries,
    /// after the images already there.
    private func insertNewBlocks(of plan: Plan, into thought: Thought, firstOrder: Int) {
        var order = firstOrder
        for planned in plan.blocks {
            if let block = planned.existing {
                var position = block.images?.count ?? 0
                for draft in planned.images where !(block.images ?? []).contains(where: { $0.id == draft.id }) {
                    insertImage(draft, order: position, into: thought, block: block)
                    position += 1
                }
            } else {
                let block = Block(id: planned.id, kind: planned.kind, content: planned.content, title: planned.title, order: order)
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

    /// Deletes the thought's inline images whose token is not in its body and, once that is
    /// saved, clears its marker. `update` runs this first on a marked thought: editing a thought
    /// that still holds such images crashes after a later rollback.
    private func removeTokenlessInlineImages(of thought: Thought) -> Bool {
        let tokens = Set(ImageToken.references(in: thought.body))
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
        let countsAsDueOpen = Scheduler.countsAsDueOpen(
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
        let parsed = items.flatMap { TagParser.parse($0.record.body) }
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
            created.colorHex = known[tag.key]?.colorHex
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
        thought.tags = TagParser.parse(record.body).compactMap { tags[$0.key] }

        let tokens = Set(ImageToken.references(in: record.body))
        for ref in record.images where tokens.contains(ref.id) {
            insertImported(ref, from: item, order: 0, into: thought, block: nil)
        }
        let blocks = record.blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
        for (order, entry) in blocks.enumerated() {
            let source = entry.element
            let id = takenBlockIDs.contains(source.id) ? UUID() : source.id
            takenBlockIDs.insert(id)
            let block = Block(id: id, kind: BlockKind(rawValue: source.kindRaw) ?? .blurred, content: source.content, title: source.title, order: order)
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
            width: ref.width, height: ref.height, order: order
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
            return BlockDraft(
                id: blockID(block.id), kind: BlockKind(rawValue: block.kindRaw) ?? .blurred, title: block.title ?? "", content: block.content,
                images: block.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { draft($0.element) }
            )
        }
        // `update` leaves `updatedAt` as it is, so the thought keeps looking older than the file until the last save.
        guard update(thought, body: record.body, blocks: blocks, images: record.images.map(draft), intervalDays: record.intervalDays, now: thought.updatedAt)
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
        thought.isPinned = record.isPinned
        thought.isArchived = record.isArchived
        thought.archivedAt = record.archivedAt
        thought.updatedAt = record.updatedAt
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
