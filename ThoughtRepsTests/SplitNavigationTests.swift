import CoreGraphics
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Split navigation")
struct SplitNavigationTests {
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func thought(_ body: String) -> Thought {
        let thought = Thought(body: body, createdAt: .now, nextDueAt: .now)
        container.mainContext.insert(thought)
        return thought
    }

    @Test func startsWithNothingSelected() {
        #expect(ThoughtSelection().current == nil)
    }

    @Test func selectAndClear() {
        let selection = ThoughtSelection()
        let a = thought("a")
        let b = thought("b")
        selection.select(a)
        #expect(selection.isSelected(a))
        selection.select(b)
        #expect(!selection.isSelected(a))
        #expect(selection.current?.id == b.id)
        selection.clear()
        #expect(selection.current == nil)
    }

    @Test func clearIfSelectedOnlyClearsThatThought() {
        let selection = ThoughtSelection()
        let a = thought("a")
        let b = thought("b")
        selection.select(a)
        selection.clear(ifSelected: b)
        #expect(selection.isSelected(a))
        selection.clear(ifSelected: a)
        #expect(selection.current == nil)
    }

    @Test func shortcutNumbersMapToSections() {
        #expect(AppTab(shortcutNumber: 1) == .timeline)
        #expect(AppTab(shortcutNumber: 2) == .tags)
        #expect(AppTab(shortcutNumber: 3) == .archive)
        #expect(AppTab(shortcutNumber: 4) == .stats)
        #expect(AppTab(shortcutNumber: 0) == nil)
        #expect(AppTab(shortcutNumber: 5) == nil)
        for tab in AppTab.allCases { #expect(AppTab(shortcutNumber: tab.shortcutNumber) == tab) }
    }

    @Test func readableMarginCentersAWideColumnOnly() {
        #expect(ReadableWidth.sideMargin(for: 390) == 0)
        #expect(ReadableWidth.sideMargin(for: ReadableWidth.column) == 0)
        #expect(ReadableWidth.sideMargin(for: 1000) == 160)
        #expect(ReadableWidth.sideMargin(for: 1000, cap: ReadableWidth.controls) == 220)
    }
}
