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

    static func randomBlocks(_ rng: inout SeededGenerator) -> [BlockDraft] {
        (0..<Int.random(in: 0...4, using: &rng)).map { _ in
            BlockDraft(
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
        let store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: {
            if let left = failureCountdown {
                failureCountdown = left - 1
                if left == 1 { throw InjectedSaveFailure() }
            }
            try $0.save()
        })
        var rng = SeededGenerator(seed: seed)
        var now = Date(timeIntervalSince1970: 1_790_000_000)

        for step in 0..<Self.stepsPerSeed {
            let thoughts = try context.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
            var op = Int.random(in: 0..<13, using: &rng)
            if thoughts.isEmpty && op >= 2 && op != 11 && op != 12 { op = 0 }
            let target = thoughts.randomElement(using: &rng)
            // About 5% of writes have one of their saves (1st to 4th) fail.
            let injectedStep: Int? = Int.random(in: 0..<20, using: &rng) == 0 ? Int.random(in: 1...4, using: &rng) : nil
            failureCountdown = injectedStep
            let description: String

            switch op {
            case 0, 1:
                let interval = Self.randomInterval(&rng)
                let blocks = Self.randomBlocks(&rng)
                store.create(body: Self.randomBody(&rng), blocks: blocks, intervalDays: interval, now: now)
                description = "create(interval: \(String(describing: interval)), blocks: \(blocks.count))"
            case 2:
                let body = Self.randomBody(&rng)
                let blocks = Self.randomBlocks(&rng)
                let interval = Self.randomInterval(&rng)
                store.update(target!, body: body, blocks: blocks, intervalDays: interval, now: now)
                description = "update(body: \(body.debugDescription), blocks: \(blocks.count), interval: \(String(describing: interval)))"
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
            default:
                now = now.addingTimeInterval(Double(Int.random(in: 1...20, using: &rng)) * 86_400)
                description = "advance now to \(now)"
            }

            let violations = try IntegrityChecker.check(context)
            #expect(
                violations.isEmpty,
                "seed \(seed) step \(step) op \(description) injected failure at save \(String(describing: injectedStep)): \(violations.map(\.description))"
            )
            if !violations.isEmpty { return }
        }
    }
}
