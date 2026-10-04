import Foundation
import SwiftData

/// Sample thoughts for previews and first runs of Debug builds, covering every state:
/// pinned, overdue, due today, waiting, archived, with and without blocks.
@MainActor
enum SampleData {
    private struct Sample {
        var body: String
        var createdDaysAgo: Int
        /// Negative = overdue by that many days; positive = waiting.
        var dueInDays: Int
        var pinned = false
        var archived = false
        var views = 0
        var interval: Int? = nil
        var blocks: [BlockDraft] = []
    }

    private static let samples: [Sample] = [
        Sample(
            body: "# Weekly review questions\nWhat moved forward? What stalled? What do I want to stop doing?\n\n#habits",
            createdDaysAgo: 40, dueInDays: 3, pinned: true, views: 5
        ),
        Sample(
            body: "# Why I'm building this\nIdeas I write down vanish. This brings them back on purpose.\n\n#projects",
            createdDaysAgo: 2, dueInDays: 5, pinned: true, views: 1
        ),
        Sample(
            body: """
            # Big-O of Swift collections
            Worth knowing cold before the next interview loop.

            - **Array** append: amortized O(1)
            - **Array** insert at front: O(n)
            - `contains` on an Array: O(n)

            #swift #study
            """,
            createdDaysAgo: 16, dueInDays: -2, views: 1,
            blocks: [BlockDraft(title: "Quiz: Set lookup?", content: "O(1) on average, because elements are hashed. Worst case O(n) with heavy collisions.")]
        ),
        Sample(
            body: "# Rubber-duck before asking\nExplain the bug out loud in full sentences first. Half the time the answer shows up.\n\n#work",
            createdDaysAgo: 7, dueInDays: 0
        ),
        Sample(
            body: """
            # Margin of safety
            Buy only when the price leaves room for being **wrong**.

            1. Estimate value conservatively
            2. Demand a discount to it

            #investing
            """,
            createdDaysAgo: 9, dueInDays: -1, views: 1,
            blocks: [BlockDraft(title: "Example", content: "A business you value at $100 a share, bought at $70.")]
        ),
        Sample(
            body: "# SwiftData relationships\nDeclare the inverse on one side only. Optional to-many arrays keep CloudKit happy.\n\n```swift\n@Relationship(inverse: \\Tag.thoughts)\nvar tags: [Tag]? = []\n```\n\n#swift",
            createdDaysAgo: 3, dueInDays: 4
        ),
        Sample(
            body: "# Two-minute rule\nIf it takes less than two minutes, do it now instead of writing it down.\n\n#habits",
            createdDaysAgo: 21, dueInDays: 1, views: 2
        ),
        Sample(
            body: "# Spanish: ser vs estar\n> Ser for what something is, estar for how it is.\n\n#study #spanish",
            createdDaysAgo: 5, dueInDays: 2, interval: 3,
            blocks: [BlockDraft(title: "Translate: The soup is cold", content: "La sopa está fría.")]
        ),
        Sample(
            body: "# Questions to ask in 1:1s\n- [ ] What's blocking you right now?\n- [ ] What should I stop doing?\n- [x] Anything you want more of?\n\n#work",
            createdDaysAgo: 30, dueInDays: 9, views: 3, interval: 14
        ),
        Sample(
            body: "# Old idea: newsletter\nShelved for now, keeping it for reference.\n\n#projects",
            createdDaysAgo: 60, dueInDays: -20, archived: true
        ),
    ]

    /// Seeds once, on the first launch of a Debug build with an empty store.
    static func seedIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.Key.didSeedSampleData) else { return }
        defaults.set(true, forKey: AppSettings.Key.didSeedSampleData)
        let count = (try? context.fetchCount(FetchDescriptor<Thought>())) ?? 0
        guard count == 0 else { return }
        insert(into: context, now: .now)
    }

    static func insert(into context: ModelContext, now: Date) {
        let store = ThoughtStore(context: context, defaultIntervalDays: Scheduler.defaultIntervalDays)
        let calendar = Calendar.current
        for sample in samples {
            let created = Scheduler.adding(days: -sample.createdDaysAgo, to: now, calendar: calendar)
            let thought = store.create(
                body: sample.body,
                blocks: sample.blocks,
                intervalDays: sample.interval,
                now: created
            )
            let nextDueAt = Scheduler.adding(days: sample.dueInDays, to: now, calendar: calendar)
                .addingTimeInterval(sample.dueInDays == 0 ? -3600 : 0) // "due today" = an hour ago
            let lastViewedAt = sample.views > 0
                ? Scheduler.adding(
                    days: -thought.effectiveIntervalDays(defaultDays: Scheduler.defaultIntervalDays),
                    to: nextDueAt,
                    calendar: calendar
                )
                : nil
            store.overrideSchedule(thought, nextDueAt: nextDueAt, lastViewedAt: lastViewedAt, viewCount: sample.views)
            if sample.pinned {
                store.setPinned(thought, true)
            }
            if sample.archived {
                store.archive(thought, now: Scheduler.adding(days: -10, to: now, calendar: calendar))
            }
        }
    }
}

/// In-memory store filled with sample data, for SwiftUI previews.
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        do {
            let container = try ModelContainer(
                for: Thought.self, Tag.self, Block.self, ImageAsset.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            SampleData.insert(into: container.mainContext, now: .now)
            return container
        } catch {
            fatalError("Preview container failed: \(error)")
        }
    }()
}
