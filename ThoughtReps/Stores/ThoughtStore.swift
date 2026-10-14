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

/// A file the user added in the editor, or a reference to one already stored. The id is the asset's.
struct FileDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var filename: String
    var typeIdentifier: String
    var byteCount: Int
    var thumbnailData: Data?
    /// The bytes of a file not saved yet; nil for a file already in the store.
    var data: Data?

    init(id: UUID = UUID(), filename: String, typeIdentifier: String, byteCount: Int, thumbnailData: Data?, data: Data?) {
        self.id = id
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.thumbnailData = thumbnailData
        self.data = data
    }

    /// A reference to a file already in the store.
    init(existing file: FileAsset) {
        self.init(
            id: file.id, filename: file.filename, typeIdentifier: file.typeIdentifier, byteCount: file.byteCount,
            thumbnailData: file.thumbnailData, data: nil
        )
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
    /// Link blocks only: the thought linked to. A draft without one, or linking to its own thought
    /// or to a target an earlier draft already links, is dropped by the store.
    var linkedThoughtID: UUID?
    /// File blocks only: the file to attach, new or already stored. A draft without one, with bytes over
    /// `FileAttachment.maxBytes`, or naming a stored file the block doesn't hold, is dropped by the store.
    var file: FileDraft?
}

/// How a detail screen was reached. An open requeues the thought; a visit from a link card only counts a view.
enum OpenKind {
    case open, visit
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
    /// Told which thoughts and tags to push after every write; a no-op while sync is off. See `SyncState`.
    var syncState: SyncState = .shared

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
            syncEnqueueContent(of: [thought.id])
        }
        return thought
    }

    /// Edits the thought to match the drafts. Saves in steps; see `persist()`.
    @discardableResult
    func update(
        _ thought: Thought, body: String, blocks: [BlockDraft], images: [ImageDraft] = [], intervalDays: Int?, now: Date
    ) -> Bool {
        // Whatever step failed, the index gets the thought as it now is.
        defer {
            reindex(ids: [thought.id])
            syncEnqueueContent(of: [thought.id])
        }
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
        if intervalChanged {
            if thought.intervalMode != .learn { reanchor(thought) }
            thought.scheduleChangedAt = now
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
        var linkedThoughtID: UUID?
        /// File blocks: the file wanted. An existing block keeps the file it has.
        var file: FileDraft?
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
        var reusableLinks = Dictionary(
            (thought.blocks ?? []).filter { $0.kind == .thoughtLink }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var claimedLinkTargets = Set<UUID>()
        var reusableFiles = Dictionary(
            (thought.blocks ?? []).filter { $0.kind == .file }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var takenFileIDs = Set((thought.files ?? []).map(\.id))

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
            case .thoughtLink:
                guard let target = draft.linkedThoughtID, target != thought.id, claimedLinkTargets.insert(target).inserted else { continue }
                let existing = reusableLinks[draft.id]
                reusableLinks[draft.id] = nil
                let id = existing != nil || !existingBlockIDs.contains(draft.id) ? draft.id : UUID()
                plan.blocks.append(PlannedBlock(
                    id: id, kind: .thoughtLink, title: nil, content: "", linkedThoughtID: target, existing: existing
                ))
            case .file:
                if let existing = reusableFiles[draft.id], let kept = existing.file {
                    reusableFiles[draft.id] = nil
                    plan.blocks.append(PlannedBlock(
                        id: existing.id, kind: .file, title: nil, content: "", file: FileDraft(existing: kept), existing: existing
                    ))
                } else if let file = draft.file, let data = file.data, data.count <= FileAttachment.maxBytes,
                          takenFileIDs.insert(file.id).inserted {
                    let id = existingBlockIDs.contains(draft.id) ? UUID() : draft.id
                    plan.blocks.append(PlannedBlock(id: id, kind: .file, title: nil, content: "", file: file, existing: nil))
                }
            }
        }
        plan.surplusBlocks = Array(reusableMarkdown) + Array(reusableGalleries.values) + Array(reusableLinks.values) + Array(reusableFiles.values)

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
            block.linkedThoughtID = planned.linkedThoughtID
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
            for file in block.files ?? [] {
                remove(file)
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
                    isBlurred: planned.isBlurred, order: order, linkedThoughtID: planned.linkedThoughtID
                )
                order += 1
                context.insert(block)
                block.thought = thought
                if let file = planned.file { insertFile(file, into: thought, block: block) }
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
        var owners = Set<UUID>()
        for block in found {
            block.kindRaw = BlockKind.markdown.rawValue
            block.isBlurred = true
            if let id = block.thought?.id { owners.insert(id) }
        }
        defer { syncState.enqueue(owners.map(SyncEntity.thought)) }
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
        if !orphans.isEmpty {
            defer { syncEnqueue(thought) }
            if !persist() { return false }
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

    private func insertFile(_ draft: FileDraft, into thought: Thought, block: Block) {
        guard let data = draft.data else { return }
        let file = FileAsset(
            id: draft.id, data: data, thumbnailData: draft.thumbnailData,
            filename: FileAttachment.sanitizedFilename(draft.filename), typeIdentifier: draft.typeIdentifier, byteCount: data.count
        )
        context.insert(file)
        file.thought = thought
        file.block = block
    }

    private func remove(_ file: FileAsset) {
        file.thought = nil
        file.block = nil
        context.delete(file)
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

    // MARK: Links

    /// Adds a link to `targetID` as the thought's last block. Rejected (false, nothing written) for a
    /// link to the thought itself or to a target it already links. The target isn't looked up, so a
    /// link can point at a thought that isn't there. Content change: `updatedAt` only, saved first,
    /// then the block alone, as `update` does for new blocks.
    @discardableResult
    func addLink(to targetID: UUID, in thought: Thought, now: Date) -> Bool {
        let blocks = thought.blocks ?? []
        guard targetID != thought.id, !blocks.contains(where: { $0.linkedThoughtID == targetID }) else { return false }
        if pendingImageSaves.ids.contains(thought.id), !removeTokenlessInlineImages(of: thought) { return false }
        let order = (blocks.map(\.order).max() ?? -1) + 1
        defer {
            reindex(ids: [thought.id])
            syncEnqueueContent(of: [thought.id])
        }
        thought.updatedAt = now
        guard persist() else { return false }
        let block = Block(kind: .thoughtLink, content: "", order: order, linkedThoughtID: targetID)
        context.insert(block)
        block.thought = thought
        return persist()
    }

    /// Removes the thought's link to `targetID`, then renumbers the remaining blocks. True if there was
    /// none. Same step order as `update`: `updatedAt`, then the deletion with the renumbering.
    @discardableResult
    func removeLink(to targetID: UUID, in thought: Thought, now: Date) -> Bool {
        guard let link = (thought.blocks ?? []).first(where: { $0.kind == .thoughtLink && $0.linkedThoughtID == targetID }) else {
            return true
        }
        if pendingImageSaves.ids.contains(thought.id), !removeTokenlessInlineImages(of: thought) { return false }
        defer {
            reindex(ids: [thought.id])
            syncEnqueueContent(of: [thought.id])
        }
        thought.updatedAt = now
        guard persist() else { return false }
        for image in link.images ?? [] {
            remove(image)
        }
        link.thought = nil
        context.delete(link)
        for (index, block) in thought.sortedBlocks.filter({ $0 !== link }).enumerated() {
            setOrder(of: block, to: index)
        }
        return persist()
    }

    // MARK: Schedule actions

    /// Records the view for a detail screen that just appeared, unless the open is archived, already
    /// recorded or carried across a layout switch. True if it wrote one.
    @discardableResult
    func recordOpen(_ thought: Thought, kind: OpenKind, hasRecordedView: Bool, handedOff: Bool, now: Date) -> Bool {
        guard ViewHandoff.recordsView(hasRecordedView: hasRecordedView, isArchived: thought.isArchived, handedOff: handedOff) else {
            return false
        }
        switch kind {
        case .open: markViewed(thought, now: now)
        case .visit: recordVisit(thought, now: now)
        }
        return true
    }

    @discardableResult
    func markViewed(_ thought: Thought, now: Date) -> Bool {
        let countsAsDueOpen = thought.intervalMode != .learn && Scheduler.countsAsDueOpen(
            isPinned: thought.isPinned,
            isArchived: thought.isArchived,
            nextDueAt: thought.nextDueAt,
            now: now
        )
        defer { syncEnqueue(thought) }
        let dueBefore = thought.nextDueAt
        thought.applyView(defaultIntervalDays: defaultIntervalDays, now: now)
        if thought.nextDueAt != dueBefore { thought.scheduleChangedAt = now }
        guard persist() else { return false }
        if countsAsDueOpen { ratingPrompt.recordDueOpen() }
        return true
    }

    /// A visit through a link: a view for the stats only. The schedule, its clock and the rating prompt stay.
    @discardableResult
    func recordVisit(_ thought: Thought, now: Date) -> Bool {
        defer { syncEnqueue(thought) }
        thought.viewCount += 1
        thought.lastViewedAt = now
        return persist()
    }

    @discardableResult
    func snooze(_ thought: Thought, days: Int, now: Date) -> Bool {
        defer { syncEnqueue(thought) }
        thought.applySnooze(days: days, now: now)
        thought.scheduleChangedAt = now
        return persist()
    }

    @discardableResult
    func setInterval(_ thought: Thought, days: Int?, now: Date) -> Bool {
        defer { syncEnqueue(thought) }
        thought.intervalDays = days
        if thought.intervalMode != .learn { reanchor(thought) }
        thought.scheduleChangedAt = now
        return persist()
    }

    /// Turning on makes the first review tomorrow; turning off goes back to the fixed interval.
    /// Schedule only: `updatedAt` stays.
    @discardableResult
    func setLearnMode(_ thought: Thought, _ enabled: Bool, now: Date) -> Bool {
        guard (thought.intervalMode == .learn) != enabled else { return true }
        defer { syncEnqueue(thought) }
        thought.learnIntervalDays = nil
        if enabled {
            thought.intervalMode = .learn
            thought.nextDueAt = Scheduler.learnStartDue(now: now)
        } else {
            thought.intervalMode = .fixed
            reanchor(thought)
        }
        thought.scheduleChangedAt = now
        return persist()
    }

    /// Rates a Learn thought that is due, unpinned and not archived; otherwise writes nothing and returns
    /// false. Not a view or an edit: `updatedAt`, `lastViewedAt` and `viewCount` stay.
    @discardableResult
    func review(_ thought: Thought, gotIt: Bool, now: Date) -> Bool {
        guard thought.intervalMode == .learn, !thought.isPinned, !thought.isArchived, thought.isDue(now: now) else { return false }
        defer { syncEnqueue(thought) }
        let result = Scheduler.afterReview(
            gotIt: gotIt,
            lastGapDays: thought.learnIntervalDays,
            now: now
        )
        thought.nextDueAt = result.nextDueAt
        thought.learnIntervalDays = result.learnIntervalDays
        thought.scheduleChangedAt = now
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
    func setColor(_ tag: Tag, hex: String?, now: Date) -> Bool {
        var normalized: String?
        if let hex {
            guard let valid = TagColor.normalizedHex(hex) else { return false }
            normalized = valid
        }
        guard tag.colorHex != normalized else { return true }
        defer { syncState.enqueue([.tag(tag.name)]) }
        tag.colorHex = normalized
        tag.updatedAt = now
        return persist()
    }

    @discardableResult
    func setPinned(_ thought: Thought, _ pinned: Bool, now: Date) -> Bool {
        let wanted = pinned && !thought.isArchived
        guard thought.isPinned != wanted else { return true }
        defer { syncEnqueue(thought) }
        thought.isPinned = wanted
        thought.stateChangedAt = now
        return persist()
    }

    @discardableResult
    func archive(_ thought: Thought, now: Date) -> Bool {
        thought.isArchived = true
        thought.isPinned = false
        thought.archivedAt = now
        thought.stateChangedAt = now
        defer {
            indexFingerprint(of: thought)
            syncEnqueue(thought)
        }
        return persist()
    }

    @discardableResult
    func restore(_ thought: Thought, now: Date) -> Bool {
        thought.isArchived = false
        thought.archivedAt = nil
        thought.nextDueAt = Scheduler.restoredDue(now: now)
        thought.stateChangedAt = now
        thought.scheduleChangedAt = now
        defer {
            indexFingerprint(of: thought)
            syncEnqueue(thought)
        }
        return persist()
    }

    @discardableResult
    func delete(_ thought: Thought, now: Date) -> Bool {
        let id = thought.id
        deleteWithChildren(thought)
        context.insert(Tombstone(id: id, kind: .thought, deletedAt: now))
        defer {
            reindex(ids: [id])
            syncState.enqueue([.thought(id)])
        }
        return persist()
    }

    /// Deletes blocks and images explicitly rather than by cascade; see `persist()`.
    private func deleteWithChildren(_ thought: Thought) {
        for block in thought.blocks ?? [] {
            for image in block.images ?? [] {
                remove(image)
            }
            for file in block.files ?? [] {
                remove(file)
            }
            block.thought = nil
            context.delete(block)
        }
        for image in thought.images ?? [] {
            remove(image)
        }
        for file in thought.files ?? [] {
            remove(file)
        }
        context.delete(thought)
    }

    /// Deletes every thought, tag and tombstone, one by one through `deleteWithChildren` so each thought's
    /// blocks and images are removed explicitly as the `persist()` note requires. A failed fetch
    /// deletes nothing and returns false.
    @discardableResult
    func deleteAll() -> Bool {
        let thoughts: [Thought]
        let tags: [Tag]
        let tombstones: [Tombstone]
        do {
            thoughts = try context.fetch(FetchDescriptor<Thought>())
            tags = try context.fetch(FetchDescriptor<Tag>())
            tombstones = try context.fetch(FetchDescriptor<Tombstone>())
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
        // No tombstones are written: whether an erase should propagate to other devices is a sync-design decision.
        for tombstone in tombstones {
            context.delete(tombstone)
        }
        guard persist() else { return false }
        searchIndex.submit(.removeAll)
        syncState.disable()
        return true
    }

    /// Sets schedule fields directly, bypassing the rules. Only for sample data,
    /// which needs thoughts in every state.
    @discardableResult
    func overrideSchedule(
        _ thought: Thought, nextDueAt: Date, lastViewedAt: Date?, viewCount: Int, learnIntervalDays: Int? = nil, now: Date
    ) -> Bool {
        defer { syncEnqueue(thought) }
        thought.scheduleChangedAt = now
        thought.nextDueAt = nextDueAt
        thought.lastViewedAt = lastViewedAt
        thought.viewCount = viewCount
        if thought.intervalMode == .learn { thought.learnIntervalDays = learnIntervalDays }
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

    /// Merges a batch read from an export, by thought id: unknown ids are added, and a stored thought
    /// is merged group by group. Content (body, blocks, images, tags) comes from the side with the newer
    /// `updatedAt`, schedule fields from the newer `scheduleChangedAt`, and state fields (pinned,
    /// archived, conflictOfID) from the newer `stateChangedAt`; each clock follows the winning side. A
    /// thought where the file wins no group is left alone, so importing the same file twice changes
    /// nothing. Adding a thought removes its tombstone, if any. A tag's color comes from the newer
    /// `Tag.updatedAt`.
    ///
    /// Added thoughts land in one save. A content merge goes through `update` (so it follows the
    /// `persist()` note: new tags are saved first, children are saved in steps) and then writes the
    /// remaining fields and clocks last; a failure part-way leaves consistent data, the thought
    /// still looks older than the file, and importing again finishes it. Returns false on the first
    /// failure with `tally` counting what was written before it. `tags` give the display name and
    /// color of tags that don't exist yet and the color of ones that do.
    @discardableResult
    func importThoughts(_ batch: [ImportedThought], tags tagInfo: [TagRecord], tally: inout ImportTally) -> Bool {
        let ids = Set(batch.map(\.record.id))
        defer {
            reindex(ids: ids)
            syncEnqueueContent(of: ids)
        }
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
        var fileOwners: [UUID: UUID?] = [:]
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
            let fileIDs = items.flatMap(\.record.fileIDs)
            for file in try context.fetch(FetchDescriptor<FileAsset>(predicate: #Predicate { fileIDs.contains($0.id) })) {
                fileOwners[file.id] = file.thought?.id
            }
            let blockIDs = items.flatMap { $0.record.blocks.map(\.id) }
            takenBlockIDs = Set(try context.fetch(FetchDescriptor<Block>(predicate: #Predicate { blockIDs.contains($0.id) })).map(\.id))
        } catch {
            Self.logger.error("Import lookup failed: \(error)")
            saveErrors.report(error)
            return false
        }

        var additions: [ImportedThought] = []
        var replacements: [(thought: Thought, item: ImportedThought, wins: GroupWins)] = []
        var claimedImageIDs = Set<UUID>()
        var claimedFileIDs = Set<UUID>()
        for item in items {
            let record = item.record
            let imageClash = record.imageIDs.contains { imageID in
                claimedImageIDs.contains(imageID) || imageOwners[imageID].map { $0 != record.id } ?? false
            }
            let fileClash = record.fileIDs.contains { fileID in
                claimedFileIDs.contains(fileID) || fileOwners[fileID].map { $0 != record.id } ?? false
            }
            if imageClash || fileClash {
                tally.rejected += 1
            } else if let current = stored[record.id] {
                let wins = GroupWins(
                    content: record.updatedAt > current.updatedAt,
                    schedule: record.scheduleClock > current.scheduleChangedAt,
                    state: record.stateClock > current.stateChangedAt,
                    counters: record.viewCount > current.viewCount || (record.lastViewedAt ?? .distantPast) > (current.lastViewedAt ?? .distantPast)
                )
                if wins.any {
                    if wins.content {
                        claimedImageIDs.formUnion(record.imageIDs)
                        claimedFileIDs.formUnion(record.fileIDs)
                    }
                    replacements.append((current, item, wins))
                } else {
                    tally.upToDate += 1
                }
            } else {
                claimedImageIDs.formUnion(record.imageIDs)
                claimedFileIDs.formUnion(record.fileIDs)
                additions.append(item)
            }
        }

        guard let tagsByName = saveTags(
            for: additions + replacements.filter(\.wins.content).map(\.item), info: tagInfo
        ) else { return false }
        guard mergeTagColors(info: tagInfo) else { return false }

        if !additions.isEmpty {
            let addedIDs = additions.map(\.record.id)
            do {
                let tombstones = try context.fetch(FetchDescriptor<Tombstone>(predicate: #Predicate { addedIDs.contains($0.id) }))
                for tombstone in tombstones where tombstone.kind == TombstoneKind.thought.rawValue {
                    context.delete(tombstone)
                }
            } catch {
                Self.logger.error("Import tombstone lookup failed: \(error)")
                saveErrors.report(error)
                return false
            }
            for item in additions {
                insertImported(item, tags: tagsByName, takenBlockIDs: &takenBlockIDs)
            }
            guard persist() else { return false }
            tally.added += additions.count
        }
        for (thought, item, wins) in replacements {
            guard replace(thought, with: item, wins: wins, takenBlockIDs: &takenBlockIDs) else { return false }
            tally.replaced += 1
        }
        return true
    }

    /// Which groups of a stored thought the imported record wins.
    private struct GroupWins {
        let content: Bool
        let schedule: Bool
        let state: Bool
        /// The file has a larger `viewCount` or a later `lastViewedAt`; counters merge by max, on no clock.
        let counters: Bool
        var any: Bool { content || schedule || state || counters }
    }

    /// Takes the color of a stored tag from the file when the file's tag is newer. Called by
    /// `importThoughts` and once per import by the caller, so a file that differs only in tag colors still merges.
    func mergeTagColors(info: [TagRecord]) -> Bool {
        let names = Set(info.map(\.name))
        guard !names.isEmpty else { return true }
        let stored: [Tag]
        do {
            stored = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { names.contains($0.name) }))
        } catch {
            Self.logger.error("Import tag color lookup failed: \(error)")
            saveErrors.report(error)
            return false
        }
        let incoming = Dictionary(info.map { ($0.name, $0) }, uniquingKeysWith: { first, second in
            second.updatedClock > first.updatedClock ? second : first
        })
        var recolored: [SyncEntity] = []
        for tag in stored {
            guard let record = incoming[tag.name], record.updatedClock > tag.updatedAt else { continue }
            tag.colorHex = record.colorHex.flatMap(TagColor.normalizedHex)
            tag.updatedAt = record.updatedClock
            recolored.append(.tag(tag.name))
        }
        defer { syncState.enqueue(recolored) }
        return !context.hasChanges || persist()
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
            let created = Tag(
                name: tag.key, displayName: known[tag.key]?.displayName ?? tag.display,
                updatedAt: known[tag.key]?.updatedClock ?? .distantPast
            )
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
        thought.createdAt = record.createdAt
        thought.updatedAt = record.updatedAt
        thought.lastViewedAt = record.lastViewedAt
        thought.viewCount = record.viewCount
        applySchedule(of: record, to: thought)
        applyState(of: record, to: thought)
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
                id: id, kind: resolved.kind, content: source.content, title: source.title, isBlurred: resolved.isBlurred, order: order,
                linkedThoughtID: source.linkedThoughtID
            )
            context.insert(block)
            block.thought = thought
            let images = source.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            for (position, image) in images.enumerated() {
                insertImported(image.element, from: item, order: position, into: thought, block: block)
            }
            if let file = source.file.flatMap({ item.files[$0.id] }) {
                insertFile(file, into: thought, block: block)
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

    private func replace(_ thought: Thought, with item: ImportedThought, wins: GroupWins, takenBlockIDs: inout Set<UUID>) -> Bool {
        let record = item.record
        if !wins.content {
            applyGroups(of: record, wins: wins, to: thought)
            return persist()
        }
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
                images: block.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { draft($0.element) },
                linkedThoughtID: block.linkedThoughtID, file: block.file.flatMap { item.files[$0.id] }
            )
        }
        // The index fingerprint is `updatedAt` plus the archive flag. If the app dies mid-replace, `updatedAt`
        // is unchanged until the last save, so reconciliation can miss the stale text until the thought is next edited.
        // `update` leaves `updatedAt` as it is, so the thought keeps looking older than the file until the last save.
        // The stored interval is passed so the content step leaves the schedule group to `applyGroups`.
        guard performUpdate(thought, body: record.body, blocks: blocks, images: record.images.map(draft), intervalDays: thought.intervalDays, now: thought.updatedAt)
        else { return false }
        takenBlockIDs = claimed
        thought.createdAt = record.createdAt
        thought.updatedAt = record.updatedAt
        applyGroups(of: record, wins: wins, to: thought)
        return persist()
    }

    private func applyGroups(of record: ThoughtRecord, wins: GroupWins, to thought: Thought) {
        if wins.schedule {
            applySchedule(of: record, to: thought)
        }
        if wins.counters {
            thought.viewCount = max(thought.viewCount, record.viewCount)
            thought.lastViewedAt = [thought.lastViewedAt, record.lastViewedAt].compactMap { $0 }.max()
        }
        if wins.state {
            applyState(of: record, to: thought)
        }
    }

    private func applySchedule(of record: ThoughtRecord, to thought: Thought) {
        thought.nextDueAt = record.nextDueAt
        thought.intervalDays = record.intervalDays
        thought.intervalModeRaw = record.intervalModeRaw
        thought.learnIntervalDays = record.learnIntervalDays
        thought.scheduleChangedAt = record.scheduleClock
    }

    private func applyState(of record: ThoughtRecord, to thought: Thought) {
        thought.isPinned = record.isPinned
        thought.isArchived = record.isArchived
        thought.archivedAt = record.archivedAt
        thought.conflictOfID = record.conflictOfID == thought.id ? nil : record.conflictOfID
        thought.stateChangedAt = record.stateClock
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
            descriptor.relationshipKeyPathsForPrefetching = [\.blocks, \.tags, \.files]
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

    // MARK: Sync outbox

    // Any new writer that changes a clock or a field a sync record carries must enqueue the thought
    // (or, for a color, the tag); extra entries are harmless, a missing one is not.

    private func syncEnqueue(_ thought: Thought) {
        syncState.enqueue([.thought(thought.id)])
    }

    /// Enqueues the thoughts and the tags they carry, which may be new. Tags come from a fresh fetch for
    /// the reason `reindex` does; a failed fetch still enqueues the thoughts.
    private func syncEnqueueContent(of ids: Set<UUID>) {
        guard syncState.isEnabled else { return }
        var entities = ids.map(SyncEntity.thought)
        let lookup = Array(ids)
        do {
            var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { lookup.contains($0.id) })
            descriptor.relationshipKeyPathsForPrefetching = [\.tags]
            for thought in try context.fetch(descriptor) {
                entities += (thought.tags ?? []).map { .tag($0.name) }
            }
        } catch {
            Self.logger.error("Sync tag fetch failed: \(error)")
        }
        syncState.enqueue(entities)
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
