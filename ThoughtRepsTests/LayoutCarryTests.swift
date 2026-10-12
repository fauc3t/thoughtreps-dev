import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Layout carry")
struct LayoutCarryTests {
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

    private func tag(_ name: String) -> ThoughtReps.Tag {
        let tag = ThoughtReps.Tag(name: name, displayName: name)
        container.mainContext.insert(tag)
        return tag
    }

    @Test func unfoldSelectsTheOpenThoughtAndKeepsTheOtherScreens() {
        let a = thought("a")
        let t = tag("t")
        let carried = LayoutCarry.unfold(compactPath: [.tag(t), .thought(a)])
        #expect(carried.thought === a)
        #expect(carried.contentPath == [.tag(t)])
    }

    @Test func unfoldWithoutAThoughtSelectsNothing() {
        let t = tag("t")
        let carried = LayoutCarry.unfold(compactPath: [.search, .tag(t)])
        #expect(carried.thought == nil)
        #expect(carried.contentPath == [.search, .tag(t)])
    }

    @Test func unfoldOfAnEmptyStackIsEmpty() {
        let carried = LayoutCarry.unfold(compactPath: [])
        #expect(carried.thought == nil)
        #expect(carried.contentPath.isEmpty)
    }

    @Test func unfoldKeepsTheLastThoughtOfSeveral() {
        let a = thought("a")
        let b = thought("b")
        let t = tag("t")
        let carried = LayoutCarry.unfold(compactPath: [.thought(a), .tag(t), .thought(b)])
        #expect(carried.thought === b)
        #expect(carried.contentPath == [.tag(t)])
    }

    @Test func foldPushesTheSelectionOnTopOfTheContentScreens() {
        let a = thought("a")
        let t = tag("t")
        #expect(LayoutCarry.fold(contentPath: [.tag(t)], selected: a) == [.tag(t), .thought(a)])
    }

    @Test func foldWithoutASelectionKeepsTheContentScreens() {
        #expect(LayoutCarry.fold(contentPath: [.search], selected: nil) == [.search])
    }

    @Test func handoffIsConsumedOnceAndOnlyForItsThought() {
        let handoff = ViewHandoff()
        let id = UUID()
        let now = Date()
        #expect(!handoff.consume(id, now: now))
        handoff.offer(id, now: now)
        #expect(!handoff.consume(UUID(), now: now))
        #expect(handoff.consume(id, now: now))
        #expect(!handoff.consume(id, now: now))
    }

    @Test func expiredOfferIsNotHonored() {
        let handoff = ViewHandoff()
        let id = UUID()
        let now = Date()
        handoff.offer(id, now: now)
        #expect(!handoff.consume(id, now: now.addingTimeInterval(ViewHandoff.window + 1)))
        #expect(!handoff.consume(id, now: now))
    }

    @Test func newerOfferReplacesOlderWithoutBeingCleared() {
        let handoff = ViewHandoff()
        let first = UUID()
        let second = UUID()
        let now = Date()
        handoff.offer(first, now: now)
        handoff.offer(second, now: now.addingTimeInterval(0.9))
        #expect(!handoff.consume(first, now: now.addingTimeInterval(0.95)))
        #expect(handoff.consume(second, now: now.addingTimeInterval(1.5)))
    }

    @Test func handedOffOpenDoesNotRecordAView() {
        #expect(ViewHandoff.recordsView(hasRecordedView: false, isArchived: false, handedOff: false))
        #expect(!ViewHandoff.recordsView(hasRecordedView: false, isArchived: false, handedOff: true))
        #expect(!ViewHandoff.recordsView(hasRecordedView: false, isArchived: true, handedOff: false))
        #expect(!ViewHandoff.recordsView(hasRecordedView: true, isArchived: false, handedOff: false))
    }

    @Test func unfoldSkipsADeletedThought() {
        let a = thought("a")
        container.mainContext.delete(a)
        #expect(LayoutCarry.unfold(compactPath: [.thought(a)]).thought == nil)
    }
}
