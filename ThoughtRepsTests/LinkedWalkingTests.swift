import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Walking linked thoughts")
struct LinkedWalkingTests {
    let container: ModelContainer
    let store: ThoughtStore
    let rating = RatingPrompt.throwaway()
    let isolated = IsolatedDefaults()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let later = Date(timeIntervalSince1970: 1_790_900_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves, ratingPrompt: rating
        )
    }

    // MARK: Card model

    @Test func presentTargetShowsTitlePreviewAndIsTappable() {
        let target = store.create(body: "# Rubber duck\nExplain it out loud.\nThen ask.", now: now)
        let model = LinkedThoughtCardModel(target: target)
        #expect(model.state == .open && model.isTappable)
        #expect(model.title == "Rubber duck")
        #expect(model.preview == "Explain it out loud. Then ask.")
        #expect(model.accessibilityLabel == "Linked thought: Rubber duck")
    }

    @Test func titleFallsBackToTheFirstPlainLine() {
        let target = store.create(body: "- first item\n- second", now: now)
        #expect(LinkedThoughtCardModel(target: target).title == "first item")
    }

    @Test func archivedTargetIsMarkedButStillTappable() {
        let target = store.create(body: "# Old", now: now)
        store.archive(target, now: later)
        let model = LinkedThoughtCardModel(target: target)
        #expect(model.state == .archived && model.isTappable)
        #expect(model.accessibilityLabel == "Linked thought: Old, archived")
    }

    @Test func missingOrDeletedTargetIsNotTappableAndHasNoPreview() {
        let missing = LinkedThoughtCardModel(target: nil)
        #expect(missing.state == .deleted && !missing.isTappable && missing.preview.isEmpty)
        #expect(missing.title == "This thought was deleted")

        let target = store.create(body: "# Gone\nbody", now: now)
        store.delete(target, now: later)
        #expect(LinkedThoughtCardModel(target: target).state == .deleted)
    }

    @Test func oneFetchResolvesPresentArchivedAndMissingTargets() {
        let hub = store.create(body: "# Hub", now: now)
        let live = store.create(body: "# Live", now: now)
        let archived = store.create(body: "# Archived", now: now)
        store.archive(archived, now: later)
        let gone = UUID()
        for id in [live.id, archived.id, gone] { store.addLink(to: id, in: hub, now: later) }

        let ids = hub.sortedBlocks.compactMap(\.linkedThoughtID)
        let targets = ThoughtCounts.targets(of: ids, in: container.mainContext)
        let states = ids.map { LinkedThoughtCardModel(target: targets[$0]).state }
        #expect(states == [.open, .archived, .deleted])
    }

    // MARK: Visit mode

    @Test func aVisitRecordsAViewWithoutRequeuing() {
        let thought = store.create(body: "# Due", now: now)
        let due = thought.nextDueAt, schedule = thought.scheduleChangedAt
        #expect(store.recordOpen(thought, kind: .visit, hasRecordedView: false, handedOff: false, now: later))
        #expect(thought.viewCount == 1 && thought.lastViewedAt == later)
        #expect(thought.nextDueAt == due && thought.scheduleChangedAt == schedule)
        #expect(rating.dueOpenCount == 0)
    }

    @Test func anOpenStillRequeues() {
        let thought = store.create(body: "# Due", now: now)
        let due = thought.nextDueAt
        #expect(store.recordOpen(thought, kind: .open, hasRecordedView: false, handedOff: false, now: later))
        #expect(thought.nextDueAt > due && thought.scheduleChangedAt == later)
    }

    @Test func aHandedOffOrRepeatedVisitIsNotCountedTwice() {
        let thought = store.create(body: "# Due", now: now)
        #expect(!store.recordOpen(thought, kind: .visit, hasRecordedView: false, handedOff: true, now: later))
        #expect(!store.recordOpen(thought, kind: .visit, hasRecordedView: true, handedOff: false, now: later))
        #expect(thought.viewCount == 0)
    }

    @Test func aVisitToAnArchivedThoughtRecordsNothing() {
        let thought = store.create(body: "# Due", now: now)
        store.archive(thought, now: later)
        #expect(!store.recordOpen(thought, kind: .visit, hasRecordedView: false, handedOff: false, now: later))
        #expect(thought.viewCount == 0)
    }

    // MARK: Layout carry

    @Test func unfoldKeepsVisitsAboveTheThoughtOnTheDetailStack() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now), c = store.create(body: "c", now: now)
        let carried = LayoutCarry.unfold(compactPath: [.thought(a), .linkedThought(b), .linkedThought(c)])
        #expect(carried.thought === a)
        #expect(carried.detailPath == [.linkedThought(b), .linkedThought(c)])
        #expect(carried.contentPath.isEmpty)
        #expect(LayoutCarry.carriedIDs(selected: a, detailPath: carried.detailPath) == [a.id, b.id, c.id])
    }

    @Test func unfoldDropsVisitsBelowTheLastThought() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now), c = store.create(body: "c", now: now)
        let carried = LayoutCarry.unfold(compactPath: [.thought(a), .linkedThought(b), .thought(c)])
        #expect(carried.thought === c)
        #expect(carried.detailPath.isEmpty)
        #expect(LayoutCarry.carriedIDs(selected: c, detailPath: []) == [c.id])
    }

    @Test func unfoldSkipsDeletedVisits() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now)
        store.delete(b, now: later)
        let carried = LayoutCarry.unfold(compactPath: [.thought(a), .linkedThought(b)])
        #expect(carried.detailPath.isEmpty)
    }

    @Test func foldPutsVisitsAboveTheSelection() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now)
        #expect(LayoutCarry.fold(contentPath: [.search], selected: a, detailPath: [.linkedThought(b)])
            == [.search, .thought(a), .linkedThought(b)])
        #expect(LayoutCarry.fold(contentPath: [.search], selected: nil, detailPath: [.linkedThought(b)]) == [.search])
    }

    @Test func foldDropsDeletedVisits() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now), c = store.create(body: "c", now: now)
        store.delete(b, now: later)
        #expect(LayoutCarry.fold(contentPath: [], selected: a, detailPath: [.linkedThought(b), .linkedThought(c)])
            == [.thought(a), .linkedThought(c)])
        #expect(LayoutCarry.carriedIDs(selected: a, detailPath: [.linkedThought(b), .linkedThought(c)]) == [a.id, c.id])
    }

    @Test func clearingADeletedThoughtTruncatesTheDetailStackAtIt() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now), c = store.create(body: "c", now: now)
        let selection = ThoughtSelection()
        selection.select(a)
        selection.detailPath = [.linkedThought(b), .linkedThought(c)]
        selection.clear(ifSelected: c)
        #expect(selection.detailPath == [.linkedThought(b)])
        selection.clear(ifSelected: b)
        #expect(selection.detailPath.isEmpty && selection.isSelected(a))
        selection.detailPath = [.linkedThought(b), .linkedThought(c)]
        selection.clear(ifSelected: a)
        #expect(selection.current == nil && selection.detailPath.isEmpty)
    }

    @Test func selectingOrClearingStartsTheDetailStackOver() {
        let a = store.create(body: "a", now: now), b = store.create(body: "b", now: now)
        let selection = ThoughtSelection()
        selection.select(a)
        selection.detailPath = [.linkedThought(b)]
        selection.select(a)
        #expect(selection.detailPath.isEmpty)
        selection.detailPath = [.linkedThought(b)]
        selection.clear()
        #expect(selection.detailPath.isEmpty)
    }
}
