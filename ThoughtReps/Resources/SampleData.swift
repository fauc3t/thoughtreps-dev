import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Sample thoughts for previews and first runs of Debug builds, covering every state:
/// pinned, overdue, due today, waiting, archived, with and without blocks.
@MainActor
enum SampleData {
    private struct Sample {
        /// `{image}` in the body becomes an inline generated image.
        var body: String
        var createdDaysAgo: Int
        /// Negative = overdue by that many days; positive = waiting.
        var dueInDays: Int
        var pinned = false
        var archived = false
        var views = 0
        var interval: Int? = nil
        var blocks: [BlockDraft] = []
        var galleryImages = 0
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
            body: "# Whiteboard from planning\nThe sketch we agreed on.\n\n{image}\n\n#projects",
            createdDaysAgo: 4, dueInDays: 3
        ),
        Sample(
            body: "# Trip moodboard\nColors and places to steal from.\n\n#projects",
            createdDaysAgo: 6, dueInDays: 1, galleryImages: 3
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
            var body = sample.body
            var blocks = sample.blocks
            var images: [ImageDraft] = []
            if body.contains("{image}"), let image = generatedImage(hue: 0.08, width: 1600, height: 1000) {
                body = body.replacingOccurrences(of: "{image}", with: ImageToken.token(for: image.id))
                images = [image]
            }
            if sample.galleryImages > 0 {
                let hues: [CGFloat] = [0.55, 0.75, 0.95]
                let gallery = hues.prefix(sample.galleryImages).enumerated().compactMap { index, hue in
                    generatedImage(hue: hue, width: index == 1 ? 1000 : 1200, height: index == 1 ? 1400 : 900)
                }
                blocks.append(BlockDraft(kind: .gallery, title: "Moodboard", images: gallery))
            }
            let thought = store.create(
                body: body,
                blocks: blocks,
                images: images,
                intervalDays: sample.interval,
                now: created
            )
            guard thought.modelContext != nil else { return }
            let nextDueAt = Scheduler.adding(days: sample.dueInDays, to: now, calendar: calendar)
                .addingTimeInterval(sample.dueInDays == 0 ? -3600 : 0) // "due today" = an hour ago
            let lastViewedAt = sample.views > 0
                ? Scheduler.adding(
                    days: -thought.effectiveIntervalDays(defaultDays: Scheduler.defaultIntervalDays),
                    to: nextDueAt,
                    calendar: calendar
                )
                : nil
            store.overrideSchedule(thought, nextDueAt: nextDueAt, lastViewedAt: lastViewedAt, viewCount: sample.views, now: now)
            if sample.pinned {
                store.setPinned(thought, true, now: now)
            }
            if sample.archived {
                store.archive(thought, now: Scheduler.adding(days: -10, to: now, calendar: calendar))
            }
        }
    }

    /// A gradient standing in for a photo.
    private static func generatedImage(hue: CGFloat, width: Int, height: Int) -> ImageDraft? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let colors = [
            CGColor(red: 1 - hue, green: 0.5, blue: hue, alpha: 1),
            CGColor(red: hue, green: 0.8, blue: 1 - hue, alpha: 1),
        ]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let processed = try? ImageProcessor.process(output as Data)
        else { return nil }
        return ImageDraft(processed: processed)
    }
}

/// In-memory store filled with sample data, for SwiftUI previews.
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        do {
            let container = try ModelContainer(
                for: Thought.self, Tag.self, Block.self, ImageAsset.self, Tombstone.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            SampleData.insert(into: container.mainContext, now: .now)
            return container
        } catch {
            fatalError("Preview container failed: \(error)")
        }
    }()
}
