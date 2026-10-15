import Foundation
import SwiftData

/// What the editor opened a thought with: the base of the 3-way merge when the stored thought has moved on.
struct EditBase: Equatable {
    var content: ThoughtContentRecord
    var intervalDays: Int?
    var learn: Bool

    @MainActor
    init(_ thought: Thought) {
        content = ThoughtContentRecord(thought)
        intervalDays = thought.intervalDays
        learn = thought.intervalMode == .learn
    }
}

extension ThoughtStore {
    /// Saves the editor's drafts over the thought it opened, without erasing what another device changed meanwhile.
    ///
    /// - Stored content still as opened: a plain `update`.
    /// - Changed since (a remote edit landed): a 3-way merge with the opened content as base, the drafts as local and
    ///   the stored content as remote. A clean merge is saved; an overlap saves the drafts and keeps the stored
    ///   version as a conflict copy (due now, `conflictOfID` set, queued and indexed).
    /// - Deleted meanwhile: the drafts are saved as a new thought, minus images and files whose bytes went with the
    ///   old one.
    ///
    /// The interval and Learn mode are only written when the editor changed them. Failure semantics are `update`'s:
    /// the drafts stay on screen, and trying again finishes the job (a copy already made is found again).
    @discardableResult
    func saveEdit(
        _ base: EditBase, body: String, blocks: [BlockDraft], images: [ImageDraft] = [], intervalDays: Int?, learn: Bool, now: Date
    ) -> Bool {
        let stored: Thought
        do {
            guard let found = try fetchThought(withID: base.content.id) else {
                return saveAsNew(body: body, blocks: blocks, images: images, intervalDays: intervalDays, learn: learn, now: now)
            }
            stored = found
        } catch {
            Self.logger.error("Thought lookup failed: \(error)")
            saveErrors.report(error)
            return false
        }

        var body = body, blocks = blocks, images = images
        let current = ThoughtContentRecord(stored)
        if !ContentMerge.sameContent(current, base.content) {
            let storedImages = storedImages(of: stored)
            let resolvable = Set(processedImages(blocks: blocks, images: images).keys).union(storedImages.values.filter(\.isInline).map(\.id))
            (body, blocks) = withoutUnresolvedTokens(body: body, blocks: blocks, resolvable: resolvable)
            let local = contentRecord(id: stored.id, body: body, blocks: blocks, images: images, storedImages: storedImages, createdAt: stored.createdAt, now: now)
            switch ContentResolver.resolve(base: base.content, local: local, remote: current) {
            case .keepLocal:
                break
            case .takeRemote:
                (body, blocks, images) = drafts(from: current, localBlocks: blocks, localImages: images, stored: stored)
            case .merged(let merged):
                (body, blocks, images) = drafts(from: merged, localBlocks: blocks, localImages: images, stored: stored)
            case .conflictCopy:
                guard makeConflictCopy(of: current, now: now) else { return false }
            }
        }

        let interval = intervalDays == base.intervalDays ? stored.intervalDays : intervalDays
        guard update(stored, body: body, blocks: blocks, images: images, intervalDays: interval, now: now) else { return false }
        return learn == base.learn || learn == (stored.intervalMode == .learn) || setLearnMode(stored, learn, now: now)
    }

    // MARK: Deleted while open

    private func saveAsNew(body: String, blocks: [BlockDraft], images: [ImageDraft], intervalDays: Int?, learn: Bool, now: Date) -> Bool {
        let processed = processedImages(blocks: blocks, images: images)
        let (body, blocks) = withoutUnresolvedTokens(body: body, blocks: blocks, resolvable: Set(processed.keys))
        let record = contentRecord(id: UUID(), body: body, blocks: blocks, images: images, storedImages: [:], createdAt: now, now: now)
        let usable = ConflictCopy.keepingAssets(
            of: record, imageIDs: Set(processed.keys),
            fileIDs: Set(blocks.compactMap { $0.file }.filter { $0.data != nil }.map(\.id))
        )
        let kept = drafts(from: usable, localBlocks: blocks, localImages: images, stored: nil)
        return create(body: kept.body, blocks: kept.blocks, images: kept.images, intervalDays: intervalDays, learn: learn, now: now).modelContext != nil
    }

    // MARK: Conflict copy of the stored version

    private func makeConflictCopy(of losing: ThoughtContentRecord, now: Date) -> Bool {
        let original = losing.id
        guard let prepared = prepareConflictCopy(of: original, losing: losing, remote: RemoteThought(id: original, content: losing), incoming: [], now: now) else {
            return false
        }
        if let item = prepared.item {
            guard let lookup = lookUp([item]) else { return false }
            var taken = lookup.takenBlockIDs
            var tally = ImportTally()
            guard execute(additions: [item], replacements: [], tags: [], takenBlockIDs: &taken, tally: &tally) else { return false }
        }
        if prepared.item != nil || prepared.alreadyHere {
            reindex(ids: [prepared.id])
            syncEnqueueContent(of: [prepared.id])
        }
        return true
    }

    // MARK: Drafts and records

    /// The drafts' inline image tokens whose image is no longer stored (the other device removed it) and isn't a new
    /// image of the editor's go, so the saved text has no dangling reference.
    private func withoutUnresolvedTokens(body: String, blocks: [BlockDraft], resolvable: Set<UUID>) -> (String, [BlockDraft]) {
        func stripped(_ text: String) -> String {
            let missing = Set(ImageToken.references(in: text)).subtracting(resolvable)
            return missing.isEmpty ? text : ImageToken.removing(missing, from: text)
        }
        let kept = blocks.map { draft -> BlockDraft in
            guard draft.kind == .markdown else { return draft }
            var copy = draft
            copy.content = stripped(draft.content)
            return copy
        }
        return (stripped(body), kept)
    }

    private func fetchThought(withID id: UUID) throws -> Thought? {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func storedImages(of thought: Thought) -> [UUID: ImageAsset] {
        Dictionary((thought.images ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func processedImages(blocks: [BlockDraft], images: [ImageDraft]) -> [UUID: ProcessedImage] {
        var found: [UUID: ProcessedImage] = [:]
        for draft in images + blocks.flatMap(\.images) {
            if let processed = draft.processed { found[draft.id] = processed }
        }
        return found
    }

    /// The content the drafts amount to, as `update` would store it: blank Markdown blocks, empty galleries, link
    /// blocks without a target (or with a repeated one) and file blocks without a file are dropped.
    private func contentRecord(
        id: UUID, body: String, blocks drafts: [BlockDraft], images inline: [ImageDraft], storedImages: [UUID: ImageAsset], createdAt: Date, now: Date
    ) -> ThoughtContentRecord {
        let processed = processedImages(blocks: drafts, images: inline)
        func imageRecord(_ id: UUID, order: Int) -> ImageRecord? {
            if let image = processed[id] { return ImageRecord(id: id, width: image.width, height: image.height, order: order) }
            return storedImages[id].map { ImageRecord(id: id, width: $0.width, height: $0.height, order: order) }
        }
        var records: [BlockRecord] = []
        var seenBlocks = Set<UUID>()
        var linkTargets = Set<UUID>()
        for draft in drafts where seenBlocks.insert(draft.id).inserted {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let order = records.count
            func record(content: String = "", blurred: Bool = false, images: [ImageRecord] = [], target: UUID? = nil, file: FileRecord? = nil) -> BlockRecord {
                BlockRecord(
                    id: draft.id, kindRaw: draft.kind.rawValue, title: title.isEmpty ? nil : title, content: content, order: order,
                    isBlurred: blurred, images: images, linkedThoughtID: target, file: file
                )
            }
            switch draft.kind {
            case .markdown:
                let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { records.append(record(content: content, blurred: draft.isBlurred)) }
            case .gallery:
                var seen = Set<UUID>()
                let images = draft.images.filter { seen.insert($0.id).inserted }.enumerated().compactMap { imageRecord($1.id, order: $0) }
                if !images.isEmpty { records.append(record(images: images)) }
            case .thoughtLink:
                if let target = draft.linkedThoughtID, linkTargets.insert(target).inserted { records.append(record(target: target)) }
            case .file:
                if let file = draft.file, (file.data?.count ?? 0) <= FileAttachment.maxBytes {
                    records.append(record(file: FileRecord(id: file.id, filename: file.filename, typeIdentifier: file.typeIdentifier, byteCount: file.byteCount)))
                }
            }
        }
        var tokens: [UUID] = []
        for text in [body] + records.filter { $0.kindRaw == BlockKind.markdown.rawValue }.map(\.content) {
            for id in ImageToken.references(in: text) where !tokens.contains(id) { tokens.append(id) }
        }
        let inlineRecords = tokens.compactMap { id in
            processed[id].map { ImageRecord(id: id, width: $0.width, height: $0.height, order: 0) }
                ?? storedImages[id].flatMap { $0.isInline ? ImageRecord(id: id, width: $0.width, height: $0.height, order: 0) : nil }
        }
        return ThoughtContentRecord(id: id, body: body, createdAt: createdAt, updatedAt: now, blocks: records, images: inlineRecords)
    }

    /// Drafts that give `update` (or `create`) the record's content. Bytes for new images and files come from the
    /// editor's own drafts; everything else is already stored.
    private func drafts(
        from record: ThoughtContentRecord, localBlocks: [BlockDraft], localImages: [ImageDraft], stored: Thought?
    ) -> (body: String, blocks: [BlockDraft], images: [ImageDraft]) {
        let processed = processedImages(blocks: localBlocks, images: localImages)
        var newFiles: [UUID: FileDraft] = [:]
        for file in localBlocks.compactMap(\.file) where file.data != nil { newFiles[file.id] = file }
        let storedFiles = Dictionary((stored?.files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func ordered<Element>(_ items: [Element], by order: (Element) -> Int) -> [Element] {
            items.enumerated().sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }.map(\.element)
        }
        let blocks = ordered(record.blocks, by: \.order).map { block in
            let resolved = block.resolved ?? (kind: .markdown, isBlurred: false)
            return BlockDraft(
                id: block.id, kind: resolved.kind, title: block.title ?? "", content: block.content, isBlurred: resolved.isBlurred,
                images: ordered(block.images, by: \.order).map { ImageDraft(id: $0.id, processed: processed[$0.id]) },
                linkedThoughtID: block.linkedThoughtID,
                file: block.file.flatMap { newFiles[$0.id] ?? storedFiles[$0.id].map(FileDraft.init(existing:)) }
            )
        }
        let inline = record.images.compactMap { image in processed[image.id].map { ImageDraft(id: image.id, processed: $0) } }
        return (record.body, blocks, inline)
    }
}
