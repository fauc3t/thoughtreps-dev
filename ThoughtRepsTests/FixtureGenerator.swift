import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// Writes `Fixtures/default.store`. Does nothing unless GENERATE_FIXTURE_TO (passed to xcodebuild as
/// TEST_RUNNER_GENERATE_FIXTURE_TO) is set to
/// an empty directory; see Fixtures/README.md for the full steps.
@MainActor
@Suite("Fixture generator")
struct FixtureGenerator {
    nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["GENERATE_FIXTURE_TO"]

    @Test(.enabled(if: outputDirectory != nil))
    func writeDefaultStore() throws {
        let directory = try #require(Self.outputDirectory)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("default.store")
        let container = try ModelContainer.thoughtReps(url: url)
        defer { withExtendedLifetime(container) {} }
        let store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400

        func photo(width: Int, height: Int) throws -> ImageDraft {
            ImageDraft(processed: try ImageProcessor.process(makeTestImageData(width: width, height: height)))
        }

        let pinned = store.create(
            body: "# Pinned idea\nKeep this on top.\n\n#Swift #study",
            blocks: [BlockDraft(title: "Quiz", content: "Answer one"), BlockDraft(content: "Answer two")],
            intervalDays: 3,
            now: t0
        )
        store.setPinned(pinned, true)

        let photoDraft = try photo(width: 96, height: 64)
        let viewed = store.create(
            body: "# Viewed twice\nWith a picture.\n\(ImageToken.token(for: photoDraft.id))\n\n#swift #café",
            images: [photoDraft],
            now: t0
        )
        store.markViewed(viewed, now: t0.addingTimeInterval(10 * day))
        store.markViewed(viewed, now: t0.addingTimeInterval(17 * day))

        let shelved = store.create(
            body: "# Shelved\nA gallery.\n\n#study",
            blocks: [BlockDraft(kind: .gallery, title: "Trip", images: [try photo(width: 64, height: 96), try photo(width: 80, height: 80)])],
            now: t0
        )
        store.archive(shelved, now: t0.addingTimeInterval(20 * day))

        store.create(body: "# Plain", now: t0)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }
}
