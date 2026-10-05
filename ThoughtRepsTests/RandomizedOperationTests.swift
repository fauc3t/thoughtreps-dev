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
                id: $0.id, kind: $0.kind, title: $0.title ?? "", content: $0.content,
                images: $0.sortedImages.map { ImageDraft(existing: $0) }
            )
        }
    }

    static func randomBlocks(_ rng: inout SeededGenerator) -> [BlockDraft] {
        (0..<Int.random(in: 0...4, using: &rng)).map { _ in
            if Int.random(in: 0..<4, using: &rng) == 0 {
                // No images drops the gallery.
                return BlockDraft(kind: .gallery, title: Bool.random(using: &rng) ? "Gallery" : "", images: randomImages(&rng, count: 0...3))
            }
            return BlockDraft(
                title: Bool.random(using: &rng) ? "Title" : "",
                // Whitespace-only content is dropped by the store, which must not leave gaps in `order`.
                content: Int.random(in: 0..<4, using: &rng) == 0 ? "  " : "content \(Int.random(in: 0..<100, using: &rng))"
            )
        }
    }

    static func randomInterval(_ rng: inout SeededGenerator) -> Int? {
        Bool.random(using: &rng) ? nil : Int.random(in: 1...Scheduler.maxIntervalDays, using: &rng)
    }

    @Test(arguments: seeds)
    func invariantsHoldAfterEveryOperation(seed: UInt64) throws {
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
        var rng = SeededGenerator(seed: seed)
        var now = Date(timeIntervalSince1970: 1_790_000_000)

        for step in 0..<Self.stepsPerSeed {
            let thoughts = try context.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
            var op = Int.random(in: 0..<17, using: &rng)
            if thoughts.isEmpty && op >= 2 && op != 11 && op != 12 { op = 0 }
            let target = thoughts.randomElement(using: &rng)
            // About 5% of writes have one of their saves (1st to 6th) fail.
            let injectedStep: Int? = Int.random(in: 0..<20, using: &rng) == 0 ? Int.random(in: 1...6, using: &rng) : nil
            failureCountdown = injectedStep
            // A third of failures also fail the next save, which defeats the take-back of early-saved images.
            doubleFailure = injectedStep != nil && Int.random(in: 0..<3, using: &rng) == 0
            let description: String

            switch op {
            case 0, 1:
                let interval = Self.randomInterval(&rng)
                let blocks = Self.randomBlocks(&rng)
                let (body, images) = Self.withInlineImages(Self.randomBody(&rng), &rng)
                store.create(body: body, blocks: blocks, images: images, intervalDays: interval, now: now)
                description = "create(interval: \(String(describing: interval)), blocks: \(blocks.count), inline: \(images.count))"
            case 2:
                let (body, images) = Self.withInlineImages(Self.randomBody(&rng), &rng)
                let blocks = Self.randomBlocks(&rng)
                let interval = Self.randomInterval(&rng)
                store.update(target!, body: body, blocks: blocks, images: images, intervalDays: interval, now: now)
                description = "update(body: \(body.debugDescription), blocks: \(blocks.count), inline: \(images.count), interval: \(String(describing: interval)))"
            case 3, 4:
                store.markViewed(target!, now: now)
                description = "markViewed"
            case 5:
                let days = Int.random(in: 1...30, using: &rng)
                store.snooze(target!, days: days, now: now)
                description = "snooze(\(days))"
            case 6:
                let days = Self.randomInterval(&rng)
                store.setInterval(target!, days: days, now: now)
                description = "setInterval(\(String(describing: days)))"
            case 7:
                let pinned = Bool.random(using: &rng)
                store.setPinned(target!, pinned)
                description = "setPinned(\(pinned))"
            case 8:
                store.archive(target!, now: now)
                description = "archive"
            case 9:
                if target!.isArchived {
                    store.restore(target!, now: now)
                    description = "restore"
                } else {
                    store.archive(target!, now: now)
                    description = "archive (instead of restore)"
                }
            case 10:
                store.delete(target!)
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
            default:
                now = now.addingTimeInterval(Double(Int.random(in: 1...20, using: &rng)) * 86_400)
                description = "advance now to \(now)"
            }

            failureCountdown = nil
            failNextSave = false
            if !store.pendingImageSaves.isEmpty && Bool.random(using: &rng) {
                store.cleanUpPendingImageSaves()
            }

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
        }

        store.cleanUpPendingImageSaves()
        #expect(store.pendingImageSaves.isEmpty)
        #expect(try IntegrityChecker.check(context).isEmpty, "seed \(seed) after final cleanup")
    }
}
