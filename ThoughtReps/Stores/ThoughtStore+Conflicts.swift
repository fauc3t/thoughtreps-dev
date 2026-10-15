import Foundation
import SwiftData

extension ThoughtStore {
    // MARK: Making a copy

    /// A conflict copy ready to insert, or nil `item` when the copy is already here (or was resolved and deleted).
    struct PreparedCopy {
        var id: UUID
        var item: ImportedThought?
        /// The copy is a stored thought already, from an earlier attempt whose cycle failed before it was queued.
        var alreadyHere = false
    }

    /// The conflict copy for `losing`, the content that lost against the thought `originalID`, as a new thought: due
    /// now, default schedule, with its own ids for blocks, images and files (their bytes copied, taken from `remote`
    /// when it brought them and from the store otherwise). The ids derive from the original and the losing content,
    /// so a second device making the same copy gets the same thought, and a copy the same batch brings is not made twice.
    /// An image or file whose bytes can't be found anywhere is left out of the copy (with its token) so sync goes on.
    /// Nil, after logging, if a lookup failed; nothing is written either way.
    func prepareConflictCopy(of originalID: UUID, losing: ThoughtContentRecord, remote: RemoteThought, incoming: Set<UUID>, now: Date) -> PreparedCopy? {
        let copyID = ConflictCopy.copyID(of: originalID, losing: losing)
        if incoming.contains(copyID) { return PreparedCopy(id: copyID, item: nil) }
        do {
            let kind = TombstoneKind.thought.rawValue
            let stored = try context.fetchCount(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == copyID }))
            let removed = try context.fetchCount(FetchDescriptor<Tombstone>(predicate: #Predicate { $0.id == copyID && $0.kind == kind }))
            if stored + removed > 0 { return PreparedCopy(id: copyID, item: nil, alreadyHere: stored > 0) }

            let wantedImages = Set((losing.images + losing.blocks.flatMap(\.images)).map(\.id))
            let wantedFiles = Set(losing.blocks.compactMap { $0.file?.id })
            var storedImages = try storedImageBytes(wantedImages.filter { remote.images[$0] == nil })
            var storedFiles = try storedFileBytes(wantedFiles.filter { remote.files[$0] == nil })
            storedImages.merge(remote.images.filter { wantedImages.contains($0.key) }) { _, new in new }
            storedFiles.merge(remote.files.filter { wantedFiles.contains($0.key) }) { _, new in new }
            let usable = ConflictCopy.keepingAssets(of: losing, imageIDs: Set(storedImages.keys), fileIDs: Set(storedFiles.keys))
            let content = ConflictCopy.content(usable, as: copyID)
            var images: [UUID: ProcessedImage] = [:]
            var files: [UUID: FileDraft] = [:]
            for old in (usable.images + usable.blocks.flatMap(\.images)).map(\.id) {
                images[ConflictCopy.derivedID(parent: copyID, source: old)] = storedImages[old]
            }
            for old in usable.blocks.compactMap({ $0.file?.id }) {
                guard var draft = storedFiles[old] else { continue }
                draft.id = ConflictCopy.derivedID(parent: copyID, source: old)
                files[draft.id] = draft
            }

            let clock = stamp(now)
            let record = ThoughtRecord(
                id: copyID, body: content.body, createdAt: content.createdAt, updatedAt: content.updatedAt,
                scheduleChangedAt: clock, stateChangedAt: clock, nextDueAt: now, lastViewedAt: nil, viewCount: 0,
                intervalDays: nil, intervalModeRaw: IntervalMode.fixed.rawValue, learnIntervalDays: nil,
                isPinned: false, isArchived: false, archivedAt: nil, conflictOfID: originalID,
                tags: [], blocks: content.blocks, images: content.images
            )
            return PreparedCopy(id: copyID, item: ImportedThought(record: record, images: images, files: files))
        } catch {
            Self.logger.error("Conflict copy of \(originalID) not made: \(error)")
            return nil
        }
    }

    private func storedImageBytes(_ ids: Set<UUID>) throws -> [UUID: ProcessedImage] {
        guard !ids.isEmpty else { return [:] }
        let lookup = Array(ids)
        var found: [UUID: ProcessedImage] = [:]
        for image in try context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { lookup.contains($0.id) })) {
            guard let data = image.data, let thumbnail = image.thumbnailData else { continue }
            found[image.id] = ProcessedImage(data: data, thumbnailData: thumbnail, width: image.width, height: image.height)
        }
        return found
    }

    private func storedFileBytes(_ ids: Set<UUID>) throws -> [UUID: FileDraft] {
        guard !ids.isEmpty else { return [:] }
        let lookup = Array(ids)
        var found: [UUID: FileDraft] = [:]
        for file in try context.fetch(FetchDescriptor<FileAsset>(predicate: #Predicate { lookup.contains($0.id) })) {
            guard let data = file.data else { continue }
            found[file.id] = FileDraft(
                id: file.id, filename: file.filename, typeIdentifier: file.typeIdentifier, byteCount: file.byteCount,
                thumbnailData: file.thumbnailData, data: data
            )
        }
        return found
    }

    /// The change clock for a merged content: a fresh stamp, and later than both merged versions unless one of
    /// those is further ahead than a clock may pull this device (`SyncClock.maxLead`).
    func mergedContentClock(local: Date, remote: Date, now: Date) -> Date {
        let clock = stamp(now)
        let floor = min(max(local, remote), now.addingTimeInterval(SyncClock.maxLead))
        guard clock <= floor else { return clock }
        let later = floor.addingTimeInterval(SyncClock.step)
        SyncClock(defaults: syncDefaults).observe(later)
        return later
    }

    // MARK: Resolving a copy

    /// The copy's content replaces the original's (a content write on the original), then the copy is deleted.
    /// False, with nothing written, if the original is gone or the copy's bytes can't be read; false if a save
    /// fails, in which case the copy is still there and trying again finishes the job.
    @discardableResult
    func keepCopy(_ copy: Thought, now: Date) -> Bool {
        guard let originalID = copy.conflictOfID, let original = thought(withID: originalID),
              let takeover = takeover(of: copy, as: originalID)
        else { return false }
        guard update(
            original, body: takeover.body, blocks: takeover.blocks, images: takeover.images, intervalDays: original.intervalDays, now: now
        ) else { return false }
        return delete(copy, now: now)
    }

    /// The copy is deleted.
    @discardableResult
    func keepOriginal(_ copy: Thought, now: Date) -> Bool {
        delete(copy, now: now)
    }

    /// The copy stays as a thought of its own.
    @discardableResult
    func keepBoth(_ copy: Thought, now: Date) -> Bool {
        guard copy.conflictOfID != nil else { return true }
        defer { syncEnqueue(copy) }
        copy.conflictOfID = nil
        copy.stateChangedAt = stamp(now)
        return persist()
    }

    private func thought(withID id: UUID) -> Thought? {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            Self.logger.error("Thought lookup failed: \(error)")
            return nil
        }
    }

    /// What `update` needs to give the thought `id` the copy's content, with ids that don't clash with the copy's own.
    private func takeover(of copy: Thought, as id: UUID) -> (body: String, blocks: [BlockDraft], images: [ImageDraft])? {
        let content = ConflictCopy.content(ThoughtContentRecord(copy), as: id)
        var images: [UUID: ProcessedImage] = [:]
        for image in copy.images ?? [] {
            guard let data = image.data, let thumbnail = image.thumbnailData else { return nil }
            images[ConflictCopy.derivedID(parent: id, source: image.id)] = ProcessedImage(
                data: data, thumbnailData: thumbnail, width: image.width, height: image.height
            )
        }
        var files: [UUID: FileDraft] = [:]
        for file in copy.files ?? [] {
            guard let data = file.data else { return nil }
            files[ConflictCopy.derivedID(parent: id, source: file.id)] = FileDraft(
                id: ConflictCopy.derivedID(parent: id, source: file.id), filename: file.filename, typeIdentifier: file.typeIdentifier,
                byteCount: file.byteCount, thumbnailData: file.thumbnailData, data: data
            )
        }
        func draft(_ ref: ImageRecord) -> ImageDraft { ImageDraft(id: ref.id, processed: images[ref.id]) }
        let blocks = content.blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { entry in
            let block = entry.element
            let resolved = block.resolved ?? (kind: .markdown, isBlurred: false)
            return BlockDraft(
                id: block.id, kind: resolved.kind, title: block.title ?? "", content: block.content, isBlurred: resolved.isBlurred,
                images: block.images.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { draft($0.element) },
                linkedThoughtID: block.linkedThoughtID, file: block.file.flatMap { files[$0.id] }
            )
        }
        return (content.body, blocks, content.images.map(draft))
    }
}
