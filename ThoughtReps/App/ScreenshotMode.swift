#if DEBUG
import SwiftUI
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Debug-only mode for the App Store screenshots (`app-store-assets/Screenshots`), switched on by the
/// `-screenshotMode` launch argument. The store is in memory and filled with `ScreenshotSeed`, so the
/// real store is never opened. Light mode, no prompts, no notification calls.
enum ScreenshotMode {
    static let isActive = CommandLine.arguments.contains("-screenshotMode")
    /// Also schedules the "Send test reminder" notification at launch. The one screenshot mode side
    /// effect outside the app: it asks the simulator for notification permission.
    static let sendsTestReminder = CommandLine.arguments.contains("-screenshotReminder")

    /// Overrides settings for this launch only: the argument domain is volatile, so nothing is persisted.
    static func overrideDefaults() {
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[AppSettings.Key.reminderEnabled] = true
        domain[AppSettings.Key.reminderMinutes] = AppSettings.defaultReminderMinutes
        domain[AppSettings.Key.defaultIntervalDays] = Scheduler.defaultIntervalDays
        domain[AppSettings.Key.thoughtFont] = ThoughtFont.paperMono.rawValue
        domain[AppSettings.Key.didSeedSampleData] = true
        domain[AppSettings.Key.ratingPromptAsked] = true
        domain[AppSettings.Key.reminderPromptAsked] = true
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    @MainActor
    static func makeContainer() throws -> ModelContainer {
        overrideDefaults()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        ScreenshotSeed.insert(into: container.mainContext, now: .now)
        return container
    }
}

/// The thoughts the marketing screenshots show. Written through `ThoughtStore` like real data.
@MainActor
enum ScreenshotSeed {
    private struct Item {
        var body: String
        var createdDaysAgo: Int
        /// Negative = overdue by that many days; 0 = due an hour ago.
        var dueInDays: Int
        var pinned = false
        var views = 0
        var gallery: (title: String, scenes: [Scene])? = nil
    }

    private static let items: [Item] = [
        Item(
            body: "# Weekly review questions\nWhat moved forward? What stalled? What do I want to stop doing?\n\nA short habit of reflection beats a long one.\n\n#habits",
            createdDaysAgo: 40, dueInDays: 3, pinned: true, views: 5
        ),
        Item(
            body: "# One wild and precious life\n“Tell me, what is it you plan to do with your one wild and precious life?” — Mary Oliver\n\n#quotes",
            createdDaysAgo: 24, dueInDays: -3, views: 2
        ),
        Item(
            body: "# Read later: the case for slow email\nSaved Tuesday, 12 min read. You said you'd get to it.\n\n#toread",
            createdDaysAgo: 10, dueInDays: 1, views: 1
        ),
        Item(
            body: "# Why journals work\nWriting builds reflection into the day. Notice what keeps coming back.\n\n#journal",
            createdDaysAgo: 17, dueInDays: -2, views: 1
        ),
        Item(
            body: """
            # Margin of safety
            Buy only when the price leaves room for being **wrong**.

            1. Estimate value conservatively
            2. Demand a discount to it
            3. Be patient: the *price* will come to you

            > The three most important words in investing.

            #investing
            """,
            createdDaysAgo: 15, dueInDays: -1, views: 1
        ),
        Item(
            body: "# Rubber-duck before asking\nExplain the bug out loud in full sentences first. Half the time the answer shows up.\n\n#work",
            createdDaysAgo: 7, dueInDays: 2
        ),
        Item(
            body: """
            # Weekend in the mountains
            Notes for the **next trip**. Keep it *slow*.

            - Pack layers, not more clothes
            - Book the early train
            - Leave one day with **no plan**

            > The point is to wander, not to arrive.

            #travel
            """,
            createdDaysAgo: 7, dueInDays: 0,
            gallery: ("Moodboard", [.dusk, .alpine, .meadow, .city])
        ),
        Item(
            body: "# Notes on reflection\nA few minutes each evening: what went well, what I would change.\n\n#journal",
            createdDaysAgo: 12, dueInDays: 4, views: 1
        ),
        Item(
            body: "# Evening pages\nThree pages, no editing. Reflection tends to show up around page two.\n\n#journal",
            createdDaysAgo: 9, dueInDays: 6, views: 1
        ),
        Item(
            body: "# Annual review\nLook back over the year and reflect on what to keep, drop and start.\n\n#habits",
            createdDaysAgo: 80, dueInDays: 12, views: 4
        ),
        Item(
            body: "# Two-minute rule\nIf it takes less than two minutes, do it now instead of writing it down.\n\n#habits",
            createdDaysAgo: 21, dueInDays: 1, views: 2
        ),
        Item(
            body: "# Spanish: ser vs estar\nSer for what something is, estar for how it is.\n\n#spanish #study",
            createdDaysAgo: 5, dueInDays: 2
        ),
        Item(
            body: "# Big-O of Swift collections\nArray append is amortized O(1). Insert at the front is O(n).\n\n#swift #study",
            createdDaysAgo: 16, dueInDays: 5, views: 1
        ),
        Item(
            body: "# Questions to ask in 1:1s\nWhat's blocking you right now? What should I stop doing?\n\n#work",
            createdDaysAgo: 30, dueInDays: 9, views: 3
        ),
    ]

    private static let tagColors: [String: String] = [
        "habits": "#3352D1",
        "quotes": "#7A4FC4",
        "toread": "#B56629",
        "journal": "#1F8A70",
        "investing": "#3F8F3A",
        "work": "#2E80AD",
        "travel": "#BF4066",
        "spanish": "#B56629",
        "study": "#5F6B7A",
        "swift": "#7A4FC4",
    ]

    static func insert(into context: ModelContext, now: Date) {
        let store = ThoughtStore(context: context, defaultIntervalDays: Scheduler.defaultIntervalDays)
        let calendar = Calendar.current
        for item in items {
            var blocks: [BlockDraft] = []
            if let gallery = item.gallery {
                let images = gallery.scenes.compactMap { $0.draft() }
                blocks.append(BlockDraft(kind: .gallery, title: gallery.title, images: images))
            }
            let created = Scheduler.adding(days: -item.createdDaysAgo, to: now, calendar: calendar)
            let thought = store.create(body: item.body, blocks: blocks, now: created)
            guard thought.modelContext != nil else {
                preconditionFailure("Screenshot seed: saving \"\(item.body.prefix(40))\" failed")
            }
            let nextDueAt = Scheduler.adding(days: item.dueInDays, to: now, calendar: calendar)
                .addingTimeInterval(item.dueInDays == 0 ? -3600 : 0)
            let lastViewedAt = item.views > 0
                ? min(
                    Scheduler.adding(
                        days: -thought.effectiveIntervalDays(defaultDays: Scheduler.defaultIntervalDays),
                        to: nextDueAt,
                        calendar: calendar
                    ),
                    Scheduler.adding(days: -1, to: now, calendar: calendar)
                )
                : nil
            store.overrideSchedule(thought, nextDueAt: nextDueAt, lastViewedAt: lastViewedAt, viewCount: item.views)
            if item.pinned { store.setPinned(thought, true) }
        }
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        for tag in tags {
            if let hex = tagColors[tag.name] { store.setColor(tag, hex: hex) }
        }
    }

    /// Simple illustrations drawn in code, so no photos or image files are bundled.
    enum Scene {
        case dusk, alpine, meadow, city

        func draft() -> ImageDraft? {
            let portrait = self == .alpine
            let width = portrait ? 1200 : 1600, height = portrait ? 1600 : 1200
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            draw(in: ctx, size: CGSize(width: width, height: height))
            let output = NSMutableData()
            guard let image = ctx.makeImage(),
                  let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination),
                  let processed = try? ImageProcessor.process(output as Data)
            else { return nil }
            return ImageDraft(processed: processed)
        }

        private func draw(in ctx: CGContext, size: CGSize) {
            let w = size.width, h = size.height
            switch self {
            case .dusk:
                sky(ctx, size, 0x3D3A6B, 0xF4A261, to: 0.62)
                disc(ctx, CGPoint(x: w * 0.5, y: h * 0.58), h * 0.13, 0xFFE8A3)
                sky(ctx, size, 0x2B4C7E, 0x1B2F52, from: 0.62)
                for i in 0..<6 {
                    let y = h * (0.64 + 0.05 * CGFloat(i))
                    let half = h * 0.12 * (1 - CGFloat(i) * 0.14)
                    fill(ctx, CGRect(x: w * 0.5 - half, y: y, width: half * 2, height: h * 0.012), 0xFFE8A3, alpha: 0.7)
                }
                hill(ctx, size, base: 0.62, amplitude: 0.025, phase: 1.0, color: 0x1B2F52)
            case .alpine:
                sky(ctx, size, 0x8EC5E8, 0xEAF6FB)
                disc(ctx, CGPoint(x: w * 0.78, y: h * 0.2), h * 0.07, 0xFFFFFF)
                peak(ctx, size, apex: CGPoint(x: w * 0.3, y: h * 0.28), baseY: 0.78, spread: 0.55, color: 0x5C6F85, cap: true)
                peak(ctx, size, apex: CGPoint(x: w * 0.78, y: h * 0.38), baseY: 0.78, spread: 0.5, color: 0x7B8FA6, cap: true)
                hill(ctx, size, base: 0.78, amplitude: 0.05, phase: 0.4, color: 0x2F6B4F)
                hill(ctx, size, base: 0.88, amplitude: 0.04, phase: 2.2, color: 0x1F4F3A)
            case .meadow:
                sky(ctx, size, 0xFFF1B8, 0x9ED8D2)
                disc(ctx, CGPoint(x: w * 0.3, y: h * 0.3), h * 0.12, 0xFFD166)
                hill(ctx, size, base: 0.58, amplitude: 0.06, phase: 0.2, color: 0x8FCB8A)
                hill(ctx, size, base: 0.7, amplitude: 0.07, phase: 1.7, color: 0x4FA66A)
                hill(ctx, size, base: 0.84, amplitude: 0.05, phase: 3.1, color: 0x2D7D4F)
            case .city:
                sky(ctx, size, 0x1E2A44, 0xE76F51, to: 0.8)
                disc(ctx, CGPoint(x: w * 0.72, y: h * 0.45), h * 0.09, 0xFFE0A3)
                let towers: [(CGFloat, CGFloat, CGFloat)] = [
                    (0.02, 0.12, 0.45), (0.14, 0.1, 0.6), (0.25, 0.14, 0.38), (0.4, 0.1, 0.55),
                    (0.51, 0.13, 0.42), (0.65, 0.1, 0.62), (0.76, 0.12, 0.4), (0.89, 0.11, 0.5),
                ]
                for (x, bw, bh) in towers {
                    let rect = CGRect(x: w * x, y: h * (1 - bh), width: w * bw, height: h * bh)
                    fill(ctx, rect, 0x14192B)
                    for row in 0..<Int(bh * 14) {
                        for col in 0..<3 where (row + col * 2 + Int(x * 100)) % 3 != 0 {
                            let window = CGRect(
                                x: rect.minX + rect.width * (0.14 + 0.28 * CGFloat(col)), y: rect.minY + h * 0.03 + CGFloat(row) * h * 0.055,
                                width: rect.width * 0.16, height: h * 0.028
                            )
                            fill(ctx, window, 0xFFD27A)
                        }
                    }
                }
            }
        }

        private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
            )
        }

        private func fill(_ ctx: CGContext, _ rect: CGRect, _ hex: UInt32, alpha: CGFloat = 1) {
            ctx.setFillColor(color(hex, alpha: alpha))
            ctx.fill(rect)
        }

        private func disc(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ hex: UInt32) {
            ctx.setFillColor(color(hex))
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        /// Vertical gradient over the band from `from` to `to` (fractions of the height).
        private func sky(_ ctx: CGContext, _ size: CGSize, _ top: UInt32, _ bottom: UInt32, from: CGFloat = 0, to: CGFloat = 1) {
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top), color(bottom)] as CFArray, locations: nil
            ) else { return }
            let y0 = size.height * from, y1 = size.height * to
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: y0, width: size.width, height: y1 - y0))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
            ctx.restoreGState()
        }

        private func hill(_ ctx: CGContext, _ size: CGSize, base: CGFloat, amplitude: CGFloat, phase: CGFloat, color hex: UInt32) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: size.height))
            let steps = 60
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let wave = sin(t * 2 * .pi * 1.3 + phase) * 0.6 + sin(t * 2 * .pi * 2.7 + phase * 2) * 0.4
                path.addLine(to: CGPoint(x: t * size.width, y: size.height * (base + amplitude * wave)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.setFillColor(color(hex))
            ctx.addPath(path)
            ctx.fillPath()
        }

        private func peak(_ ctx: CGContext, _ size: CGSize, apex: CGPoint, baseY: CGFloat, spread: CGFloat, color hex: UInt32, cap: Bool) {
            let base = size.height * baseY, half = size.width * spread / 2
            let body = CGMutablePath()
            body.move(to: CGPoint(x: apex.x - half, y: base))
            body.addLine(to: apex)
            body.addLine(to: CGPoint(x: apex.x + half, y: base))
            body.closeSubpath()
            ctx.setFillColor(color(hex))
            ctx.addPath(body)
            ctx.fillPath()
            guard cap else { return }
            let snowDrop = (base - apex.y) * 0.28, snowHalf = half * 0.28
            let snow = CGMutablePath()
            snow.move(to: apex)
            snow.addLine(to: CGPoint(x: apex.x - snowHalf, y: apex.y + snowDrop))
            snow.addLine(to: CGPoint(x: apex.x - snowHalf * 0.3, y: apex.y + snowDrop * 0.8))
            snow.addLine(to: CGPoint(x: apex.x + snowHalf * 0.2, y: apex.y + snowDrop * 1.05))
            snow.addLine(to: CGPoint(x: apex.x + snowHalf, y: apex.y + snowDrop))
            snow.closeSubpath()
            ctx.setFillColor(color(0xFFFFFF))
            ctx.addPath(snow)
            ctx.fillPath()
        }
    }
}
#endif
