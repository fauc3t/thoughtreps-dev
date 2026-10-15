import Foundation

/// The 3-way merge of a thought's content (spec section 8a): blocks by id first, then each markdown text line by
/// line (diff3 over `CollectionDifference`). Pure. Any overlap anywhere is a `.conflict`; there is no partial merge.
enum ContentMerge {
    enum Outcome: Equatable {
        case merged(ThoughtContentRecord)
        case conflict
    }

    private struct Conflict: Error {}

    /// An unchanged side returns the other side exactly. Otherwise the result carries the later `updatedAt`
    /// of the two, which the caller replaces with a fresh content clock.
    static func merge(base: ThoughtContentRecord, local: ThoughtContentRecord, remote: ThoughtContentRecord) -> Outcome {
        if local == remote { return .merged(local) }
        if sameContent(local, base) { return .merged(remote) }
        if sameContent(remote, base) { return .merged(local) }
        if sameContent(local, remote) { return .merged(local.updatedAt >= remote.updatedAt ? local : remote) }
        do {
            return .merged(try mergedRecord(base: base, local: local, remote: remote))
        } catch {
            return .conflict
        }
    }

    /// Equal apart from `updatedAt` and `createdAt`, and apart from how block and image orders are numbered.
    static func sameContent(_ a: ThoughtContentRecord, _ b: ThoughtContentRecord) -> Bool {
        a.body == b.body && ordered(a.blocks) == ordered(b.blocks) && sortedImages(a.images) == sortedImages(b.images)
    }

    // MARK: Whole record

    private static func mergedRecord(base: ThoughtContentRecord, local: ThoughtContentRecord, remote: ThoughtContentRecord) throws -> ThoughtContentRecord {
        var body = try mergeText(base.body, local.body, remote.body)
        let baseBlocks = Side(base), localBlocks = Side(local), remoteBlocks = Side(remote)

        var merged: [UUID: BlockRecord] = [:]
        for id in Set(baseBlocks.order + localBlocks.order + remoteBlocks.order) {
            if let block = try mergeBlock(baseBlocks.byID[id], localBlocks.byID[id], remoteBlocks.byID[id]) {
                merged[id] = block
            }
        }
        var blocks = arranged(merged, base: baseBlocks, local: localBlocks, remote: remoteBlocks)

        dropExtraTokenLines(
            body: &body, blocks: &blocks,
            allowed: [base, local, remote].map { tokenLineCounts(in: texts(of: $0)) }
        )
        blocks = blocks.compactMap { block in
            guard block.resolved?.kind == .markdown else { return block }
            var trimmed = block
            trimmed.content = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.content.isEmpty ? nil : trimmed
        }
        var seenTargets = Set<UUID>()
        blocks = blocks.filter { block in
            guard block.resolved?.kind == .thoughtLink, let target = block.linkedThoughtID else { return true }
            return seenTargets.insert(target).inserted
        }
        blocks = blocks.enumerated().map { index, block in
            var numbered = block
            numbered.order = index
            numbered.images = block.images.enumerated().map { position, image in
                var numbered = image
                numbered.order = position
                return numbered
            }
            return numbered
        }

        let tokens = Set(([body] + blocks.filter { $0.resolved?.kind == .markdown }.map(\.content)).flatMap { ImageToken.references(in: $0) })
        var pool: [UUID: ImageRecord] = [:]
        for image in remote.images + local.images { pool[image.id] = image }
        let inline = sortedImages(tokens.compactMap { pool[$0] })

        let imageIDs = inline.map(\.id) + blocks.flatMap { $0.images.map(\.id) }
        let fileIDs = blocks.compactMap { $0.file?.id }
        guard Set(imageIDs).count == imageIDs.count, Set(fileIDs).count == fileIDs.count else { throw Conflict() }

        return ThoughtContentRecord(
            id: local.id, body: body, createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: max(local.updatedAt, remote.updatedAt), blocks: blocks, images: inline
        )
    }

    // MARK: Blocks

    private struct Side {
        var order: [UUID]
        var byID: [UUID: BlockRecord]

        init(_ record: ThoughtContentRecord) {
            let blocks = ContentMerge.ordered(record.blocks)
            order = blocks.map(\.id)
            byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Blocks in display order, with the gallery images in theirs.
    private static func ordered(_ blocks: [BlockRecord]) -> [BlockRecord] {
        blocks.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.enumerated().map { index, entry in
            var block = entry.element
            block.order = index
            block.images = sortedImages(block.images)
            return block
        }
    }

    private static func sortedImages(_ images: [ImageRecord]) -> [ImageRecord] {
        images.enumerated().sorted { ($0.element.order, $0.element.id.uuidString, $0.offset) < ($1.element.order, $1.element.id.uuidString, $1.offset) }
            .enumerated().map { position, entry in
                var image = entry.element
                image.order = position
                return image
            }
    }

    private static func sameBlock(_ a: BlockRecord, _ b: BlockRecord) -> Bool {
        func shape(_ block: BlockRecord) -> BlockRecord {
            var copy = block
            copy.order = 0
            copy.images = sortedImages(block.images)
            return copy
        }
        return shape(a) == shape(b)
    }

    /// The merged block, or nil if it is gone (removed, or its text merged away). Throws on an overlap.
    private static func mergeBlock(_ base: BlockRecord?, _ local: BlockRecord?, _ remote: BlockRecord?) throws -> BlockRecord? {
        switch (base, local, remote) {
        case (nil, nil, nil), (_?, nil, nil):
            return nil
        case (nil, let added?, nil), (nil, nil, let added?):
            return added
        case (nil, let a?, let b?):
            guard sameBlock(a, b) else { throw Conflict() }
            return a
        case (let base?, nil, let kept?), (let base?, let kept?, nil):
            guard sameBlock(base, kept) else { throw Conflict() }
            return nil
        case (let base?, let local?, let remote?):
            if sameBlock(local, base) { return remote }
            if sameBlock(remote, base) { return local }
            if sameBlock(local, remote) { return local }
            guard base.kindRaw == local.kindRaw, base.kindRaw == remote.kindRaw else { throw Conflict() }
            var result = remote
            result.title = try mergeValue(base.title, local.title, remote.title)
            switch base.resolved?.kind {
            case .markdown:
                result.isBlurred = try mergeValue(base.isBlurred, local.isBlurred, remote.isBlurred)
                result.content = try mergeText(base.content, local.content, remote.content)
            case .gallery:
                result.images = mergeGallery(base.images, local.images, remote.images)
                if result.images.isEmpty { return nil }
            default:
                throw Conflict()
            }
            return result
        }
    }

    private static func mergeValue<Value: Equatable>(_ base: Value, _ local: Value, _ remote: Value) throws -> Value {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        throw Conflict()
    }

    /// A set by id, since images never change: what either side removed is gone, what either added is in. The remote
    /// order wins; images only the local side added follow in its order.
    private static func mergeGallery(_ base: [ImageRecord], _ local: [ImageRecord], _ remote: [ImageRecord]) -> [ImageRecord] {
        let baseIDs = Set(base.map(\.id))
        let removedLocally = baseIDs.subtracting(local.map(\.id))
        let remoteIDs = Set(remote.map(\.id))
        let kept = sortedImages(remote).filter { !removedLocally.contains($0.id) }
        let added = sortedImages(local).filter { !baseIDs.contains($0.id) && !remoteIDs.contains($0.id) }
        return kept + added
    }

    /// The surviving blocks in order: the remote order if it moved anything, else the local one. Blocks one side added
    /// go after the nearest block before them on that side that survived.
    private static func arranged(_ merged: [UUID: BlockRecord], base: Side, local: Side, remote: Side) -> [BlockRecord] {
        let common = Set(merged.keys).intersection(base.byID.keys)
        let remoteSpine = remote.order.filter(common.contains)
        var order = remoteSpine == base.order.filter(common.contains) ? local.order.filter(common.contains) : remoteSpine
        for side in [remote, local] {
            for (index, id) in side.order.enumerated() where merged[id] != nil && base.byID[id] == nil && !order.contains(id) {
                let anchor = side.order[..<index].last { order.contains($0) }
                order.insert(id, at: anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
            }
        }
        return order.compactMap { merged[$0] }
    }

    // MARK: Text

    private static func mergeText(_ base: String, _ local: String, _ remote: String) throws -> String {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        let baseLines = lines(base)
        let mine = hunks(from: baseLines, to: lines(local))
        let theirs = hunks(from: baseLines, to: lines(remote))
        var output: [String] = []
        var position = 0
        func emit(_ hunk: Hunk) throws {
            guard hunk.start >= position else { throw Conflict() }
            output += baseLines[position..<hunk.start]
            output += hunk.lines
            position = hunk.end
        }
        var i = 0, j = 0
        while i < mine.count || j < theirs.count {
            guard i < mine.count else { try emit(theirs[j]); j += 1; continue }
            guard j < theirs.count else { try emit(mine[i]); i += 1; continue }
            let a = mine[i], b = theirs[j]
            if a == b {
                try emit(a)
                i += 1
                j += 1
            } else if a.overlaps(b) {
                // One side's rewrite that already holds the other's (same lines at the shared edge) agrees with it there.
                if a.includes(b) {
                    try emit(a)
                    i += 1
                    j += 1
                } else if b.includes(a) {
                    try emit(b)
                    i += 1
                    j += 1
                } else {
                    throw Conflict()
                }
            } else if a.end <= b.start {
                try emit(a)
                i += 1
            } else {
                try emit(b)
                j += 1
            }
        }
        output += baseLines[position...]
        return output.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A change in terms of the base: lines `start..<end` are replaced by `lines` (an insertion when `start == end`).
    private struct Hunk: Equatable {
        var start: Int
        var end: Int
        var lines: [String]

        /// This change covers the other's base lines and ends with the other's replacement at the shared start or end.
        func includes(_ other: Hunk) -> Bool {
            guard start <= other.start, other.end <= end, !other.lines.isEmpty else { return false }
            return (other.end == end && lines.count > other.lines.count && lines.suffix(other.lines.count) == other.lines[...])
                || (other.start == start && lines.count > other.lines.count && lines.prefix(other.lines.count) == other.lines[...])
        }

        /// Changes that touch the same base lines, or insert at the same place. Changes that merely touch don't.
        func overlaps(_ other: Hunk) -> Bool {
            if start == end && other.start == other.end { return start == other.start }
            return start < other.end && other.start < end
        }
    }

    private static func hunks(from old: [String], to new: [String]) -> [Hunk] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Hunk] = []
        var open: Hunk?
        var i = 0, j = 0
        while i < old.count || j < new.count {
            let isRemoved = i < old.count && removed.contains(i)
            let isInserted = j < new.count && inserted.contains(j)
            if isRemoved || isInserted {
                var hunk = open ?? Hunk(start: i, end: i, lines: [])
                if isRemoved {
                    hunk.end = i + 1
                    i += 1
                } else {
                    hunk.lines.append(new[j])
                    j += 1
                }
                open = hunk
            } else {
                if let hunk = open { result.append(hunk) }
                open = nil
                i += 1
                j += 1
            }
        }
        if let hunk = open { result.append(hunk) }
        return result
    }

    // MARK: Image tokens

    private static func texts(of record: ThoughtContentRecord) -> [String] {
        [record.body] + ordered(record.blocks).filter { $0.resolved?.kind == .markdown }.map(\.content)
    }

    /// The image a line consists of alone, if it is one.
    private static func tokenLineID(_ line: String) -> UUID? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ids = ImageToken.references(in: trimmed)
        return ids.count == 1 && ImageToken.removing(from: trimmed).isEmpty ? ids[0] : nil
    }

    private static func tokenLineCounts(in texts: [String]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for line in texts.flatMap(lines) {
            if let id = tokenLineID(line) { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Both sides can move one token to different places, which would put it in the text twice. The later lines go,
    /// down to the most any one input had.
    private static func dropExtraTokenLines(body: inout String, blocks: inout [BlockRecord], allowed: [[UUID: Int]]) {
        let markdown = blocks.indices.filter { blocks[$0].resolved?.kind == .markdown }
        var counts = tokenLineCounts(in: [body] + markdown.map { blocks[$0].content })
        func limit(_ id: UUID) -> Int { allowed.map { $0[id] ?? 0 }.max() ?? 0 }
        guard counts.contains(where: { $0.value > limit($0.key) }) else { return }
        func trimmed(_ text: String) -> String {
            var kept = lines(text)
            for index in kept.indices.reversed() {
                if let id = tokenLineID(kept[index]), counts[id, default: 0] > limit(id) {
                    kept.remove(at: index)
                    counts[id, default: 0] -= 1
                }
            }
            return kept.joined(separator: "\n")
        }
        for index in markdown.reversed() { blocks[index].content = trimmed(blocks[index].content) }
        body = trimmed(body)
    }
}
