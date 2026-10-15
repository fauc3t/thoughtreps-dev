import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// SplitMix64: tiny, deterministic, and good enough to drive test operations.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct InjectedSaveFailure: Error {}

/// Runs random sequences of store operations and checks `IntegrityChecker` after each one.
@MainActor
@Suite("Randomized store operations")
struct RandomizedOperationTests {
    nonisolated static let seeds: [UInt64] = Array(1...20)
    static let stepsPerSeed = 200

    static let tagPool = [
        "#swift", "#Swift", "#SWIFT", "#caf\u{E9}", "#cafe\u{301}", "#CAF\u{C9}",
        "#\u{C9}tude", "#e\u{301}tude", "#work", "#a-b", "#Work_2", "#naïve",
    ]
    static let colorChoices: [String?] = [nil, "#3352D1", "#5f6b7a", "5F6B7A", "#12345", "red", "#GGGGGG", ""]
    static let words = ["alpha", "beta", "gamma", "delta", "idea", "review", "note"]

    static func randomBody(_ rng: inout SeededGenerator) -> String {
        var lines = ["# \(words.randomElement(using: &rng)!) \(Int.random(in: 0..<1000, using: &rng))"]
        lines.append((0..<Int.random(in: 0...3, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " "))
        if Bool.random(using: &rng) {
            lines.append("```\n#incode\n```")
        }
        let tagCount = Int.random(in: 0...4, using: &rng)
        lines.append((0..<tagCount).map { _ in tagPool.randomElement(using: &rng)! }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    static func randomFile(_ rng: inout SeededGenerator) -> FileDraft {
        fakeFile(UInt8.random(in: 0...255, using: &rng), name: ["notes.pdf", "a b.txt", "x/y:z.csv", ".hidden"].randomElement(using: &rng)!)
    }

    static func randomImages(_ rng: inout SeededGenerator, count: ClosedRange<Int>) -> [ImageDraft] {
        (0..<Int.random(in: count, using: &rng)).map { _ in newImage(UInt8.random(in: 0...255, using: &rng)) }
    }

    /// New inline images, some referenced from the body they are appended to and some not.
    static func withInlineImages(_ body: String, _ rng: inout SeededGenerator) -> (body: String, images: [ImageDraft]) {
        let images = randomImages(&rng, count: 0...3)
        var body = body
        for image in images where Int.random(in: 0..<4, using: &rng) != 0 {
            body += "\n" + ImageToken.token(for: image.id)
        }
        return (body, images)
    }

    static func currentDrafts(of thought: Thought) -> [BlockDraft] {
        thought.sortedBlocks.map {
            BlockDraft(
                id: $0.id, kind: $0.kind, title: $0.title ?? "", content: $0.content, isBlurred: $0.isBlurred,
                images: $0.sortedImages.map { ImageDraft(existing: $0) }, linkedThoughtID: $0.linkedThoughtID,
                file: $0.kind == .file ? $0.file.map { FileDraft(existing: $0) } : nil
            )
        }
    }

    /// Each link block with its owner and the owner's `updatedAt`, to check that deleting a target leaves them be.
    static func linkSnapshot(_ context: ModelContext, excluding excluded: UUID) throws -> [String] {
        try context.fetch(FetchDescriptor<Thought>()).filter { $0.id != excluded }.flatMap { thought in
            (thought.blocks ?? []).filter { $0.kind == .thoughtLink }.map {
                "\(thought.id) \($0.id) \($0.linkedThoughtID?.uuidString ?? "-") \($0.order) \(thought.updatedAt.timeIntervalSince1970)"
            }
        }.sorted()
    }

    static func randomBlocks(_ rng: inout SeededGenerator, linkable: [UUID] = []) -> [BlockDraft] {
        (0..<Int.random(in: 0...4, using: &rng)).map { _ in
            if Int.random(in: 0..<5, using: &rng) == 0 {
                // Targets may be live, missing, repeated, the thought itself (when `linkable` holds it) or absent.
                return BlockDraft(kind: .thoughtLink, linkedThoughtID: (linkable.map(Optional.some) + [UUID(), nil]).randomElement(using: &rng)!)
            }
            if Int.random(in: 0..<8, using: &rng) == 0 {
                // No file drops the block.
                return BlockDraft(kind: .file, file: Int.random(in: 0..<5, using: &rng) == 0 ? nil : randomFile(&rng))
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                // No images drops the gallery.
                return BlockDraft(kind: .gallery, title: Bool.random(using: &rng) ? "Gallery" : "", images: randomImages(&rng, count: 0...3))
            }
            var content = Int.random(in: 0..<4, using: &rng) == 0 ? "  " : "content \(Int.random(in: 0..<100, using: &rng))"
            if Bool.random(using: &rng) { content += " " + tagPool.randomElement(using: &rng)! }
            return BlockDraft(
                title: Bool.random(using: &rng) ? "Title" : "",
                // Whitespace-only content is dropped by the store, which must not leave gaps in `order`.
                content: content,
                isBlurred: Bool.random(using: &rng)
            )
        }
    }

    /// Moves some of the body's inline image tokens into the content of markdown blocks.
    static func moveTokensToBlocks(body: inout String, images: [ImageDraft], blocks: inout [BlockDraft], _ rng: inout SeededGenerator) {
        let targets = blocks.indices.filter { blocks[$0].kind == .markdown }
        guard !targets.isEmpty else { return }
        for image in images where body.contains(ImageToken.token(for: image.id)) && Bool.random(using: &rng) {
            body = body.replacingOccurrences(of: ImageToken.token(for: image.id), with: "")
            blocks[targets.randomElement(using: &rng)!].content += "\n" + ImageToken.token(for: image.id)
        }
    }

    /// A thought as an export file would hold it: with the id and creation date of `existing` when given, and
    /// an `updatedAt` on either side of its current one.
    static func randomImported(replacing existing: Thought?, id: UUID? = nil, now: Date, _ rng: inout SeededGenerator) -> ImportedThought {
        var images: [UUID: ProcessedImage] = [:]
        var files: [UUID: FileDraft] = [:]
        func imageRecord(order: Int) -> ImageRecord {
            let id = UUID()
            images[id] = fakeImage(UInt8.random(in: 0...255, using: &rng))
            return ImageRecord(id: id, width: 40, height: 30, order: order)
        }
        var body = randomBody(&rng)
        let inline = (0..<Int.random(in: 0...2, using: &rng)).map { _ in imageRecord(order: 0) }
        for image in inline where Int.random(in: 0..<4, using: &rng) != 0 {
            body += "\n" + ImageToken.token(for: image.id)
        }
        let blocks: [BlockRecord] = (0..<Int.random(in: 0...3, using: &rng)).map { order in
            if Int.random(in: 0..<3, using: &rng) == 0 {
                let gallery = (0..<Int.random(in: 1...3, using: &rng)).map { imageRecord(order: $0) }
                return BlockRecord(id: UUID(), kindRaw: BlockKind.gallery.rawValue, title: nil, content: "", order: order, images: gallery.shuffled(using: &rng))
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                let draft = randomFile(&rng)
                files[draft.id] = draft
                return BlockRecord(
                    id: UUID(), kindRaw: BlockKind.file.rawValue, title: nil, content: "", order: order, images: [],
                    file: FileRecord(id: draft.id, filename: draft.filename, typeIdentifier: draft.typeIdentifier, byteCount: draft.byteCount)
                )
            }
            let legacy = Int.random(in: 0..<3, using: &rng) == 0
            return BlockRecord(
                id: UUID(), kindRaw: legacy ? BlockKind.legacyBlurredRaw : BlockKind.markdown.rawValue, title: "T",
                content: "content \(order) \(tagPool.randomElement(using: &rng)!)", order: order,
                isBlurred: !legacy && Bool.random(using: &rng), images: []
            )
        }
        let createdAt = existing?.createdAt ?? now.addingTimeInterval(-86_400)
        let updatedAt = max(createdAt, (existing?.updatedAt ?? now).addingTimeInterval(Double(Int.random(in: -100...100, using: &rng))))
        func clock(_ current: Date?) -> Date? {
            Int.random(in: 0..<4, using: &rng) == 0
                ? nil
                : max(createdAt, (current ?? now).addingTimeInterval(Double(Int.random(in: -100...100, using: &rng))))
        }
        let scheduleChangedAt = clock(existing?.scheduleChangedAt)
        let stateChangedAt = clock(existing?.stateChangedAt)
        let archived = Int.random(in: 0..<4, using: &rng) == 0
        let viewed = Bool.random(using: &rng)
        let learning = Int.random(in: 0..<3, using: &rng) == 0
        let imported = ThoughtRecord(
            id: existing?.id ?? id ?? UUID(), body: body, createdAt: createdAt, updatedAt: updatedAt,
            scheduleChangedAt: scheduleChangedAt, stateChangedAt: stateChangedAt,
            nextDueAt: now.addingTimeInterval(86_400), lastViewedAt: viewed ? now : nil, viewCount: viewed ? 2 : 0,
            intervalDays: randomInterval(&rng), intervalModeRaw: (learning ? IntervalMode.learn : IntervalMode.fixed).rawValue,
            learnIntervalDays: learning && Bool.random(using: &rng) ? Int.random(in: 1...Scheduler.maxIntervalDays, using: &rng) : nil,
            isPinned: !archived && Bool.random(using: &rng), isArchived: archived, archivedAt: archived ? updatedAt : nil,
            conflictOfID: Int.random(in: 0..<4, using: &rng) == 0 ? (Bool.random(using: &rng) ? (existing?.id ?? id ?? UUID()) : UUID()) : nil,
            tags: [], blocks: blocks, images: inline
        )
        return ImportedThought(record: imported, images: images, files: files)
    }

    static func randomInterval(_ rng: inout SeededGenerator) -> Int? {
        Bool.random(using: &rng) ? nil : Int.random(in: 1...Scheduler.maxIntervalDays, using: &rng)
    }

    /// The sync fingerprints of everything the store holds, to see what a step changed.
    struct SyncSnapshot {
        var thoughts: [UUID: String] = [:]
        var tags: [String: String] = [:]
    }

    /// Tags no thought carries are left out: an orphan (say, from a failed import) needn't be pushed, and is pruned at launch.
    static func syncSnapshot(_ context: ModelContext) throws -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        var used = Set<String>()
        for thought in try context.fetch(FetchDescriptor<Thought>()) {
            snapshot.thoughts[thought.id] = SyncPayload.thoughtContent(ThoughtContentRecord(thought)).fingerprint
                + SyncPayload.thoughtMeta(ThoughtMetaRecord(thought)).fingerprint
            used.formUnion((thought.tags ?? []).map(\.name))
        }
        for tag in try context.fetch(FetchDescriptor<ThoughtReps.Tag>()) where used.contains(tag.name) {
            snapshot.tags[tag.name] = "\(SyncFingerprint.tag(updatedAt: tag.updatedAt)) \(tag.displayName) \(tag.colorHex ?? "-")"
        }
        return snapshot
    }

    @Test(arguments: seeds)
    func invariantsHoldAfterEveryOperation(seed: UInt64) async throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        var failureCountdown: Int? = nil
        var failNextSave = false
        var doubleFailure = false
        let suiteName = "randomized-\(seed)-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: {
            if failNextSave {
                failNextSave = false
                throw InjectedSaveFailure()
            }
            if let left = failureCountdown {
                failureCountdown = left - 1
                if left == 1 {
                    failNextSave = doubleFailure
                    throw InjectedSaveFailure()
                }
            }
            try $0.save()
        })
        store.pendingImageSaves = PendingImageSaves(defaults: defaults)
        store.ratingPrompt = RatingPrompt(defaults: defaults)
        let index = SearchIndex(location: .inMemory)
        store.searchIndex = index
        store.syncDefaults = defaults
        let syncState = SyncState(location: .inMemory)
        try await syncState.configure(vaultID: "randomized")
        store.syncState = syncState
        var syncSnapshot = try Self.syncSnapshot(context)
        var rng = SeededGenerator(seed: seed)
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var deletedIDs = Set<UUID>()

        for step in 0..<Self.stepsPerSeed {
            let thoughts = try context.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
            var op = Int.random(in: 0..<32, using: &rng)
            if op == 22 && Int.random(in: 0..<6, using: &rng) != 0 { op = 12 }
            if thoughts.isEmpty && op >= 2 && op != 11 && op != 12 && op != 18 && op != 22 && op != 23 { op = 0 }
            let target = thoughts.randomElement(using: &rng)
            // About 5% of writes have one of their saves (1st to 6th) fail.
            let injectedStep: Int? = Int.random(in: 0..<20, using: &rng) == 0 ? Int.random(in: 1...6, using: &rng) : nil
            failureCountdown = injectedStep
            // A third of failures also fail the next save, which defeats the take-back of early-saved images.
            doubleFailure = injectedStep != nil && Int.random(in: 0..<3, using: &rng) == 0
            let description: String
            let before = target.map { [$0.updatedAt, $0.scheduleChangedAt, $0.stateChangedAt] }
            // Content, schedule and state clock indexes the operation may move.
            var allowedClocks: Set<Int>?

            switch op {
            case 0, 1:
                let interval = Self.randomInterval(&rng)
                let learn = Int.random(in: 0..<4, using: &rng) == 0
                var blocks = Self.randomBlocks(&rng, linkable: thoughts.map(\.id))
                var (body, images) = Self.withInlineImages(Self.randomBody(&rng), &rng)
                Self.moveTokensToBlocks(body: &body, images: images, blocks: &blocks, &rng)
                store.create(body: body, blocks: blocks, images: images, intervalDays: interval, learn: learn, now: now)
                description = "create(interval: \(String(describing: interval)), learn: \(learn), blocks: \(blocks.count), inline: \(images.count))"
            case 2:
                var (body, images) = Self.withInlineImages(Self.randomBody(&rng), &rng)
                var blocks = Self.randomBlocks(&rng, linkable: thoughts.map(\.id))
                Self.moveTokensToBlocks(body: &body, images: images, blocks: &blocks, &rng)
                let interval = Self.randomInterval(&rng)
                store.update(target!, body: body, blocks: blocks, images: images, intervalDays: interval, now: now)
                allowedClocks = [0, 1]
                description = "update(body: \(body.debugDescription), blocks: \(blocks.count), inline: \(images.count), interval: \(String(describing: interval)))"
            case 3, 4:
                store.markViewed(target!, now: now)
                allowedClocks = [1]
                description = "markViewed"
            case 5:
                let days = Int.random(in: 1...30, using: &rng)
                store.snooze(target!, days: days, now: now)
                allowedClocks = [1]
                description = "snooze(\(days))"
            case 6:
                let days = Self.randomInterval(&rng)
                store.setInterval(target!, days: days, now: now)
                allowedClocks = [1]
                description = "setInterval(\(String(describing: days)))"
            case 7:
                let pinned = Bool.random(using: &rng)
                store.setPinned(target!, pinned, now: now)
                allowedClocks = [2]
                description = "setPinned(\(pinned))"
            case 8:
                store.archive(target!, now: now)
                allowedClocks = [2]
                description = "archive"
            case 9:
                if target!.isArchived {
                    store.restore(target!, now: now)
                    allowedClocks = [1, 2]
                    description = "restore"
                } else {
                    store.archive(target!, now: now)
                    allowedClocks = [2]
                    description = "archive (instead of restore)"
                }
            case 10:
                let doomed = target!.id
                if store.delete(target!, now: now) { deletedIDs.insert(doomed) }
                description = "delete"
            case 11:
                store.pruneOrphanTags()
                description = "pruneOrphanTags"
            case 13:
                let image = newImage(UInt8.random(in: 0...255, using: &rng))
                let body = target!.body + "\n" + ImageToken.token(for: image.id)
                store.update(target!, body: body, blocks: Self.currentDrafts(of: target!), images: [image], intervalDays: target!.intervalDays, now: now)
                description = "add inline image"
            case 14:
                let tokens = ImageToken.references(in: target!.body)
                let body = tokens.randomElement(using: &rng).map {
                    target!.body.replacingOccurrences(of: ImageToken.token(for: $0), with: "")
                } ?? target!.body
                store.update(target!, body: body, blocks: Self.currentDrafts(of: target!), intervalDays: target!.intervalDays, now: now)
                description = "remove a token (of \(tokens.count))"
            case 15:
                var drafts = Self.currentDrafts(of: target!)
                drafts.insert(
                    BlockDraft(kind: .gallery, title: "New", images: Self.randomImages(&rng, count: 1...3)),
                    at: Int.random(in: 0...drafts.count, using: &rng)
                )
                store.update(target!, body: target!.body, blocks: drafts, intervalDays: target!.intervalDays, now: now)
                description = "add gallery"
            case 16:
                var drafts = Self.currentDrafts(of: target!)
                let galleries = drafts.indices.filter { drafts[$0].kind == .gallery }
                if let index = galleries.randomElement(using: &rng) {
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: drafts.remove(at: index)
                    case 1: drafts[index].images.shuffle(using: &rng)
                    case 2:
                        if !drafts[index].images.isEmpty { drafts[index].images.remove(at: Int.random(in: 0..<drafts[index].images.count, using: &rng)) }
                    default:
                        drafts[index].images.insert(
                            newImage(UInt8.random(in: 0...255, using: &rng)),
                            at: Int.random(in: 0...drafts[index].images.count, using: &rng)
                        )
                    }
                }
                store.update(target!, body: target!.body, blocks: drafts, intervalDays: target!.intervalDays, now: now)
                description = "edit gallery (of \(galleries.count))"
            case 17:
                let items = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                    Self.randomImported(replacing: Bool.random(using: &rng) ? target : nil, now: now, &rng)
                }
                var tally = ImportTally()
                let tagInfo = try context.fetch(FetchDescriptor<ThoughtReps.Tag>(sortBy: [SortDescriptor(\.name)])).map {
                    TagRecord(
                        name: $0.name, displayName: $0.displayName, colorHex: Self.colorChoices.randomElement(using: &rng)!,
                        updatedAt: Bool.random(using: &rng) ? $0.updatedAt.addingTimeInterval(Double(Int.random(in: -100...100, using: &rng))) : nil
                    )
                }
                store.importThoughts(items, tags: tagInfo, tally: &tally)
                description = "import(\(items.count), replacing: \(items.filter { $0.record.id == target?.id }.count), added: \(tally.added), replaced: \(tally.replaced))"
            case 18:
                let tags = try context.fetch(FetchDescriptor<ThoughtReps.Tag>(sortBy: [SortDescriptor(\.name)]))
                let hex = Self.colorChoices.randomElement(using: &rng)!
                if let tag = tags.randomElement(using: &rng) {
                    store.setColor(tag, hex: hex, now: now)
                    description = "setColor(\(tag.name), \(String(describing: hex)))"
                } else {
                    description = "setColor (no tags)"
                }
            case 19:
                let enabled = Bool.random(using: &rng)
                store.setLearnMode(target!, enabled, now: now)
                allowedClocks = [1]
                description = "setLearnMode(\(enabled))"
            case 20, 21:
                if target!.intervalMode == .learn {
                    let gotIt = op == 20
                    store.review(target!, gotIt: gotIt, now: now)
                    allowedClocks = [1]
                    description = gotIt ? "review(got it)" : "review(again)"
                } else {
                    store.setLearnMode(target!, true, now: now)
                    allowedClocks = [1]
                    description = "setLearnMode(true) (instead of review)"
                }
            case 24:
                let linkTarget = (thoughts.map(\.id) + [UUID()]).randomElement(using: &rng)!
                store.addLink(to: linkTarget, in: target!, now: now)
                allowedClocks = [0]
                description = "add link (to self: \(linkTarget == target!.id))"
            case 25:
                if let linkTarget = target!.sortedBlocks.compactMap(\.linkedThoughtID).randomElement(using: &rng) {
                    store.removeLink(to: linkTarget, in: target!, now: now)
                    description = "remove link"
                } else {
                    description = "remove link (none)"
                }
                allowedClocks = [0]
            case 26:
                let linked = try context.fetch(FetchDescriptor<Block>()).filter { $0.kind == .thoughtLink }.compactMap(\.linkedThoughtID)
                let live = Dictionary(thoughts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                if let doomed = linked.filter({ live[$0] != nil }).randomElement(using: &rng), let victim = live[doomed] {
                    let untouched = try Self.linkSnapshot(context, excluding: doomed)
                    if store.delete(victim, now: now) { deletedIDs.insert(doomed) }
                    #expect(try Self.linkSnapshot(context, excluding: doomed) == untouched, "seed \(seed) step \(step) delete touched linking thoughts")
                    description = "delete a link target"
                } else {
                    description = "delete a link target (none)"
                }
            case 27:
                var drafts = Self.currentDrafts(of: target!)
                drafts.insert(BlockDraft(kind: .file, file: Self.randomFile(&rng)), at: Int.random(in: 0...drafts.count, using: &rng))
                store.update(target!, body: target!.body, blocks: drafts, intervalDays: target!.intervalDays, now: now)
                allowedClocks = [0]
                description = "add file block"
            case 28:
                var drafts = Self.currentDrafts(of: target!)
                let files = drafts.indices.filter { drafts[$0].kind == .file }
                if let index = files.randomElement(using: &rng) { drafts.remove(at: index) }
                store.update(target!, body: target!.body, blocks: drafts, intervalDays: target!.intervalDays, now: now)
                allowedClocks = [0]
                description = "remove file block (of \(files.count))"
            case 29:
                let local = ThoughtContentRecord(target!)
                var base = local
                base.body += "\nbase-line"
                base.updatedAt = local.updatedAt.addingTimeInterval(-500)
                var remote = local
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: remote.body = base.body + "\nremote \(Int.random(in: 0..<1000, using: &rng))"
                case 1: remote.body = Self.randomBody(&rng)
                default: remote.body = "remote head\n" + local.body
                }
                var arrived: [UUID: ProcessedImage] = [:]
                if Bool.random(using: &rng) {
                    let image = UUID()
                    arrived[image] = fakeImage(UInt8.random(in: 0...255, using: &rng))
                    remote.body += "\n" + ImageToken.token(for: image)
                    remote.images.append(ImageRecord(id: image, width: 40, height: 30, order: 0))
                }
                if Bool.random(using: &rng) {
                    let image = UUID()
                    arrived[image] = fakeImage(UInt8.random(in: 0...255, using: &rng))
                    remote.blocks.append(BlockRecord(
                        id: UUID(), kindRaw: BlockKind.gallery.rawValue, title: nil, content: "", order: remote.blocks.count,
                        images: [ImageRecord(id: image, width: 40, height: 30, order: 0)]
                    ))
                }
                remote.updatedAt = max(local.createdAt, local.updatedAt.addingTimeInterval(Double(Int.random(in: -1000...1000, using: &rng))))
                let outcome = store.applyRemote(
                    RemoteBatch(thoughts: [RemoteThought(
                        id: target!.id, content: remote, contentBase: base,
                        contentBaseHash: SyncPayload.hash(of: try SyncPayload.thoughtContent(base).encoded()), images: arrived
                    )]),
                    now: now
                )
                syncState.enqueue(Array(outcome.requeue))
                syncSnapshot = try Self.syncSnapshot(context)
                description = "applyRemote of a colliding version (saved: \(outcome.saved), requeue: \(outcome.requeue.count))"
            case 30:
                let found = ThoughtCounts.conflictCopies(limit: 5, in: context).thoughts
                if let copy = found.randomElement(using: &rng) {
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0:
                        let kept = store.keepCopy(copy, now: now)
                        description = "keepCopy (\(kept))"
                    case 1:
                        let id = copy.id
                        if store.keepOriginal(copy, now: now) { deletedIDs.insert(id) }
                        description = "keepOriginal"
                    default:
                        store.keepBoth(copy, now: now)
                        description = "keepBoth"
                    }
                } else {
                    description = "resolve a copy (none)"
                }
            case 31:
                let base = EditBase(target!)
                let drafts = Self.currentDrafts(of: target!)
                let interval = target!.intervalDays
                let opened = target!.body
                failureCountdown = nil
                let doomed = target!.id
                let concurrent = Int.random(in: 0..<4, using: &rng)
                switch concurrent {
                case 1: store.update(target!, body: "remote head\n" + opened, blocks: drafts, intervalDays: interval, now: now)
                case 2: store.update(target!, body: Self.randomBody(&rng), blocks: drafts, intervalDays: interval, now: now)
                case 3: if store.delete(target!, now: now) { deletedIDs.insert(doomed) }
                default: break
                }
                failureCountdown = injectedStep
                let edited = (opened + "\nedited \(Int.random(in: 0..<1000, using: &rng))").trimmingCharacters(in: .whitespacesAndNewlines)
                let saved = store.saveEdit(base, body: edited, blocks: drafts, intervalDays: interval, learn: base.learn, now: now)
                description = "saveEdit over a concurrent change (\(concurrent), saved: \(saved))"
            case 22:
                store.deleteAll()
                description = "deleteAll"
            case 23:
                let items = [Self.randomImported(replacing: nil, id: deletedIDs.sorted { $0.uuidString < $1.uuidString }.randomElement(using: &rng), now: now, &rng)]
                var tally = ImportTally()
                store.importThoughts(items, tags: [], tally: &tally)
                description = "import a possibly deleted id (added: \(tally.added))"
            default:
                now = now.addingTimeInterval(Double(Int.random(in: 1...20, using: &rng)) * 86_400)
                description = "advance now to \(now)"
            }

            failureCountdown = nil
            failNextSave = false
            if let allowedClocks, let target, let before {
                let after = [target.updatedAt, target.scheduleChangedAt, target.stateChangedAt]
                let moved = Set(after.indices.filter { after[$0] != before[$0] })
                #expect(moved.isSubset(of: allowedClocks), "seed \(seed) step \(step) op \(description) moved clocks \(moved)")
            }
            if !store.pendingImageSaves.isEmpty && Bool.random(using: &rng) {
                store.cleanUpPendingImageSaves()
            }

            let currentSnapshot = try Self.syncSnapshot(context)
            if op == 22 && !syncState.isEnabled {
                try await syncState.configure(vaultID: "randomized")
                #expect(try await syncState.outboxCount() == 0, "seed \(seed) step \(step) deleteAll left outbox entries")
            } else {
                let queued = Set(try await syncState.outbox(limit: Int.max).map(\.entity))
                for (id, fingerprint) in currentSnapshot.thoughts where syncSnapshot.thoughts[id] != fingerprint {
                    #expect(queued.contains(.thought(id)), "seed \(seed) step \(step) op \(description) changed thought \(id) without queueing it")
                }
                for id in syncSnapshot.thoughts.keys where currentSnapshot.thoughts[id] == nil {
                    #expect(queued.contains(.thought(id)), "seed \(seed) step \(step) op \(description) removed thought \(id) without queueing it")
                }
                for (name, fingerprint) in currentSnapshot.tags where syncSnapshot.tags[name] != fingerprint {
                    #expect(queued.contains(.tag(name)), "seed \(seed) step \(step) op \(description) changed tag \(name) without queueing it")
                }
            }
            syncSnapshot = currentSnapshot
            // Drained every step, so each step must queue what it changed by itself.
            try await markEverythingSynced(context: context, state: syncState, defaults: defaults)

            var violations = try IntegrityChecker.check(context)
            let marked = store.pendingImageSaves.ids
            // Only token-less inline images of marked thoughts are tolerated.
            violations.removeAll { violation in
                violation.description.hasPrefix("Inline image") && marked.contains { violation.description.contains($0.uuidString) }
            }
            #expect(
                violations.isEmpty,
                "seed \(seed) step \(step) op \(description) injected failure at save \(String(describing: injectedStep)): \(violations.map(\.description))"
            )
            if !violations.isEmpty { return }

            let indexViolations = try await SearchIndexChecker.check(context, index: index)
            #expect(
                indexViolations.isEmpty,
                "seed \(seed) step \(step) op \(description) injected failure at save \(String(describing: injectedStep)): \(indexViolations)"
            )
            if !indexViolations.isEmpty { return }
        }

        store.cleanUpPendingImageSaves()
        #expect(store.pendingImageSaves.isEmpty)
        #expect(try IntegrityChecker.check(context).isEmpty, "seed \(seed) after final cleanup")
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty, "seed \(seed) index after final cleanup")

        let fresh = SyncState(location: .inMemory)
        try await fresh.configure(vaultID: "reconciled")
        let storeContainer = container
        let settings = SettingsRecord.current(defaults: defaults)
        let first = try await Task.detached {
            try await SyncReconciler(modelContainer: storeContainer).reconcile(state: fresh, settings: settings)
        }.value
        #expect(first.thoughts == syncSnapshot.thoughts.count, "seed \(seed) first sync queues every thought")
        try await markEverythingSynced(context: context, state: fresh, defaults: defaults)
        let second = try await Task.detached {
            try await SyncReconciler(modelContainer: storeContainer).reconcile(state: fresh, settings: settings)
        }.value
        #expect(second.total == 0, "seed \(seed) nothing to sync once everything is synced")
    }
}
