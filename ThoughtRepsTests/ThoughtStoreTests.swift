import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import ThoughtReps

/// Store behavior against an in-memory SwiftData container, with a fixed clock.
@MainActor
@Suite("ThoughtStore")
struct ThoughtStoreTests {
    let container: ModelContainer
    let store: ThoughtStore
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway())
    }

    func days(_ n: Int, from date: Date) -> Date {
        Scheduler.adding(days: n, to: date, calendar: .current)
    }

    func tagNames() throws -> [String] {
        try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).map(\.name).sorted()
    }

    @Test func setColorSavesNormalizedHexAndResetsToAutomatic() throws {
        let tag = try #require(store.create(body: "# A\n#swift", now: now).tags?.first)
        #expect(store.setColor(tag, hex: "#3352d1", now: now))
        #expect(tag.colorHex == "#3352D1")
        #expect(store.setColor(tag, hex: "5f6b7a", now: now))
        #expect(tag.colorHex == "#5F6B7A")
        #expect(store.setColor(tag, hex: nil, now: now))
        #expect(tag.colorHex == nil)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test(arguments: ["", "red", "#12345", "#1234567", "#GGGGGG", "##123456", "+123456", "#12345\u{FF16}"])
    func setColorRejectsInvalidHex(hex: String) throws {
        let tag = try #require(store.create(body: "# A\n#swift", now: now).tags?.first)
        store.setColor(tag, hex: "#3352D1", now: now)
        #expect(!store.setColor(tag, hex: hex, now: now))
        #expect(tag.colorHex == "#3352D1")
    }

    @Test func failedSetColorRollsBack() throws {
        let errors = SaveErrorCenter()
        let tag = try #require(store.create(body: "# A\n#swift", now: now).tags?.first)
        store.setColor(tag, hex: "#3352D1", now: now)
        let failing = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: errors, save: { _ in throw InjectedSaveFailure() })
        #expect(!failing.setColor(tag, hex: "#BF4066", now: now))
        #expect(tag.colorHex == "#3352D1")
        #expect(errors.message != nil)
    }

    @Test(arguments: ["red", "3352D1", "#12345"])
    func integrityCheckerFlagsBadColorHex(hex: String) throws {
        let tag = try #require(store.create(body: "# A\n#swift", now: now).tags?.first)
        tag.colorHex = hex
        #expect(try IntegrityChecker.check(container.mainContext).count == 1)
        tag.colorHex = "#3352d1"
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func automaticPaletteIsTheOriginalSix() {
        #expect(TagColor.palette.count == 6)
        #expect(TagColor.swatches.prefix(6).map(\.hex) == ["#3352D1", "#1F8A70", "#B56629", "#7A4FC4", "#BF4066", "#2E80AD"])
        #expect(TagColor.swatches.count == 8)
    }

    @Test func customColorHexRoundsAndClamps() throws {
        #expect(TagColor.hex(red: 1, green: 0.5, blue: 0) == "#FF8000")
        #expect(TagColor.hex(red: 1.2, green: -0.1, blue: 0.2) == "#FF0033")
        let srgb = UIColor(red: 0x12 / 255, green: 0x34 / 255, blue: 0x56 / 255, alpha: 0.5)
        #expect(TagColor.hex(for: srgb) == "#123456")
        let p3 = UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let hex = try #require(TagColor.hex(for: p3))
        #expect(TagColor.normalizedHex(hex) == hex)
        #expect(hex.hasPrefix("#FF"))
    }

    @Test func customMeansNeitherAutomaticNorASwatch() {
        #expect(!TagColor.isCustom(nil))
        #expect(!TagColor.isCustom("#3352d1"))
        #expect(TagColor.isCustom("#123456"))
        #expect(!TagColor.isCustom("not a color"))
    }

    @Test func setColorKeepsACustomHex() throws {
        let tag = try #require(store.create(body: "# A\n#swift", now: now).tags?.first)
        #expect(store.setColor(tag, hex: "#abcdef", now: now))
        #expect(tag.colorHex == "#ABCDEF")
        #expect(TagColor.isCustom(tag.colorHex))
        // A custom pick that matches a swatch shows as that swatch.
        #expect(store.setColor(tag, hex: "#1f8a70", now: now))
        #expect(!TagColor.isCustom(tag.colorHex))
    }

    @Test func grayAndLightCustomColors() {
        #expect(TagColor.hex(for: UIColor(white: 1, alpha: 1)) == "#FFFFFF")
        #expect(TagColor.checkmarkColor(onHex: "#FFFFFF") == .black)
        #expect(TagColor.checkmarkColor(onHex: "#3352D1") == .white)
        #expect(TagColor.checkmarkColor(onHex: nil) == .white)
    }

    @Test func newThoughtWaitsForItsInterval() {
        let thought = store.create(body: "Hello", now: now)
        #expect(thought.nextDueAt == days(7, from: now))
        #expect(!thought.isDue(now: now))
        #expect(thought.viewCount == 0)
    }

    @Test func viewRequeuesFromNow() {
        let thought = store.create(body: "Hello", now: now)
        let later = days(10, from: now)
        store.markViewed(thought, now: later)
        #expect(thought.viewCount == 1)
        #expect(thought.lastViewedAt == later)
        #expect(thought.nextDueAt == days(7, from: later))
    }

    @Test func snoozeMovesDueWithoutCountingAView() {
        let thought = store.create(body: "Hello", now: now)
        store.snooze(thought, days: 1, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
        #expect(thought.viewCount == 0)
        #expect(thought.lastViewedAt == nil)
    }

    @Test func editingTheIntervalReschedules() {
        let thought = store.create(body: "Hello", now: now)
        store.update(thought, body: "Hello", blocks: [], intervalDays: 1, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
    }

    @Test func editingWithoutIntervalChangeKeepsSchedule() {
        let thought = store.create(body: "Hello", now: now)
        store.snooze(thought, days: 30, now: now)
        store.update(thought, body: "Edited", blocks: [], intervalDays: nil, now: now)
        #expect(thought.nextDueAt == days(30, from: now))
    }

    @Test func editingTheIntervalReanchorsFromLastView() {
        let thought = store.create(body: "Hello", now: now)
        let viewed = days(10, from: now)
        store.markViewed(thought, now: viewed)
        store.update(thought, body: "Hello", blocks: [], intervalDays: 2, now: days(11, from: now))
        #expect(thought.nextDueAt == days(2, from: viewed))
    }

    @Test func setIntervalMatchesEditorPath() {
        let viaMenu = store.create(body: "A", now: now)
        let viaEditor = store.create(body: "B", now: now)
        store.setInterval(viaMenu, days: 3, now: now)
        store.update(viaEditor, body: "B", blocks: [], intervalDays: 3, now: now)
        #expect(viaMenu.nextDueAt == viaEditor.nextDueAt)
    }

    @Test func turningLearnOnSchedulesTomorrowAndOffReanchors() throws {
        let thought = store.create(body: "Hello", now: now)
        let later = days(2, from: now)
        #expect(store.setLearnMode(thought, true, now: later))
        #expect(thought.intervalMode == .learn && thought.learnIntervalDays == nil)
        #expect(thought.nextDueAt == days(1, from: later))
        #expect(thought.updatedAt == now && thought.scheduleChangedAt == later)
        #expect(!thought.isDue(now: later))

        let off = days(5, from: now)
        #expect(store.setLearnMode(thought, false, now: off))
        #expect(thought.intervalMode == .fixed && thought.learnIntervalDays == nil)
        #expect(thought.nextDueAt == days(7, from: now))
        #expect(thought.updatedAt == now && thought.scheduleChangedAt == off)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func settingLearnToItsCurrentValueWritesNothing() {
        let thought = store.create(body: "Hello", now: now)
        #expect(store.setLearnMode(thought, false, now: days(1, from: now)))
        #expect(thought.updatedAt == now)
    }

    @Test func reviewsGrowAndResetWithoutTouchingViews() throws {
        let thought = store.create(body: "Hello", learn: true, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
        let t1 = days(1, from: now)
        #expect(store.review(thought, gotIt: true, now: t1))
        #expect(thought.learnIntervalDays == 7 && thought.nextDueAt == days(7, from: t1))
        let t2 = days(7, from: t1)
        #expect(store.review(thought, gotIt: true, now: t2))
        #expect(thought.learnIntervalDays == 12 && thought.nextDueAt == days(12, from: t2))
        let t3 = days(12, from: t2)
        #expect(store.review(thought, gotIt: false, now: t3))
        #expect(thought.learnIntervalDays == nil && thought.nextDueAt == days(1, from: t3))
        #expect(thought.viewCount == 0 && thought.lastViewedAt == nil && thought.updatedAt == now)
        #expect(thought.intervalDays == nil)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func reviewUsesThoughtsFixedIntervalAsBase() {
        let thought = store.create(body: "Hello", intervalDays: 3, learn: true, now: now)
        store.review(thought, gotIt: true, now: days(1, from: now))
        #expect(thought.learnIntervalDays == 3)
    }

    @Test func reviewIgnoresNonLearnThoughts() {
        let thought = store.create(body: "Hello", now: now)
        #expect(!store.review(thought, gotIt: true, now: now))
        #expect(thought.nextDueAt == days(7, from: now) && thought.learnIntervalDays == nil)
    }

    @Test func reviewOnlyAppliesToDueUnpinnedLearnThoughts() {
        let thought = store.create(body: "Hello", learn: true, now: now)
        #expect(!store.review(thought, gotIt: true, now: now))
        let due = days(1, from: now)
        #expect(store.review(thought, gotIt: true, now: due))
        let after = thought.nextDueAt
        #expect(!store.review(thought, gotIt: true, now: due))
        #expect(thought.nextDueAt == after && thought.learnIntervalDays == 7)

        let pinned = store.create(body: "P", learn: true, now: now)
        store.setPinned(pinned, true, now: now)
        #expect(!store.review(pinned, gotIt: true, now: due))
        let archived = store.create(body: "A", learn: true, now: now)
        store.archive(archived, now: now)
        #expect(!store.review(archived, gotIt: true, now: due))
        #expect(archived.learnIntervalDays == nil)
    }

    @Test func settingTheIntervalOfALearnThoughtKeepsItsScheduleAndIsNotAnEdit() {
        let thought = store.create(body: "Hello", learn: true, now: now)
        let later = days(1, from: now)
        #expect(store.setInterval(thought, days: 3, now: later))
        #expect(thought.intervalDays == 3 && thought.nextDueAt == days(1, from: now) && thought.updatedAt == now && thought.scheduleChangedAt == later)
    }

    @Test func editorChainedSaveTurnsLearnOnAfterAnIntervalChange() {
        let thought = store.create(body: "Hello", now: now)
        let later = days(2, from: now)
        #expect(store.update(thought, body: "Hello", blocks: [], intervalDays: 3, now: later))
        #expect(store.setLearnMode(thought, true, now: later))
        #expect(thought.intervalMode == .learn && thought.learnIntervalDays == nil)
        #expect(thought.intervalDays == 3 && thought.nextDueAt == days(1, from: later))
    }

    @Test func editorChainedSaveTurnsLearnOffAfterAnIntervalChange() {
        let thought = store.create(body: "Hello", learn: true, now: now)
        store.review(thought, gotIt: true, now: days(1, from: now))
        let later = days(5, from: now)
        #expect(store.update(thought, body: "Hello", blocks: [], intervalDays: 3, now: later))
        #expect(store.setLearnMode(thought, false, now: later))
        #expect(thought.intervalMode == .fixed && thought.learnIntervalDays == nil)
        #expect(thought.nextDueAt == days(3, from: thought.createdAt))
    }

    @Test func openingALearnThoughtCountsAViewButStaysDue() {
        let thought = store.create(body: "Hello", learn: true, now: now)
        let opened = days(3, from: now)
        store.markViewed(thought, now: opened)
        #expect(thought.viewCount == 1 && thought.lastViewedAt == opened)
        #expect(thought.nextDueAt == days(1, from: now))
        #expect(thought.isDue(now: opened))
    }

    @Test func editingTheIntervalOfALearnThoughtKeepsItsSchedule() {
        let thought = store.create(body: "Hello", learn: true, now: now)
        store.update(thought, body: "Hello", blocks: [], intervalDays: 3, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
    }

    @Test func failedLearnWritesRollBack() throws {
        let thought = store.create(body: "Hello", now: now)
        let failing = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            save: { _ in throw CocoaError(.fileWriteUnknown) }, ratingPrompt: .throwaway()
        )
        #expect(!failing.setLearnMode(thought, true, now: now))
        #expect(thought.intervalMode == .fixed)
        #expect(thought.nextDueAt == days(7, from: now))
    }

    @Test func archiveAndRestore() {
        let thought = store.create(body: "Hello", now: now)
        store.setPinned(thought, true, now: now)
        store.archive(thought, now: now)
        #expect(thought.isArchived)
        #expect(!thought.isPinned)
        let later = days(3, from: now)
        store.restore(thought, now: later)
        #expect(!thought.isArchived)
        #expect(thought.archivedAt == nil)
        #expect(thought.isDue(now: later))
    }

    @Test func tagsAreSharedCaseInsensitively() throws {
        let a = store.create(body: "#Swift notes", now: now)
        let b = store.create(body: "more #swift", now: now)
        #expect(try tagNames() == ["swift"])
        #expect(a.tags?.first?.displayName == "Swift")
        #expect(b.tags?.first?.persistentModelID == a.tags?.first?.persistentModelID)
    }

    @Test func tagRemovedFromBodyIsPrunedAtLaunch() throws {
        let thought = store.create(body: "#swift #study", now: now)
        store.update(thought, body: "#swift", blocks: [], intervalDays: nil, now: now)
        #expect(try tagNames() == ["study", "swift"]) // kept until launch
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func pruneKeepsTagsStillInUse() throws {
        let a = store.create(body: "#swift #study", now: now)
        store.create(body: "#swift", now: now)
        store.delete(a, now: now)
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func archivedThoughtsKeepTheirTags() throws {
        let thought = store.create(body: "#swift", now: now)
        store.archive(thought, now: now)
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func blocksAreReplacedOnEdit() {
        let thought = store.create(body: "Q", blocks: [BlockDraft(content: "A1")], now: now)
        store.update(thought, body: "Q", blocks: [BlockDraft(content: "A2"), BlockDraft(content: "  ")], intervalDays: nil, now: now)
        #expect(thought.sortedBlocks.map(\.content) == ["A2"])
    }

    @Test func deleteAllEmptiesTheStore() throws {
        store.create(body: "#a", blocks: [BlockDraft(content: "x")], now: now)
        store.create(body: "#b", now: now)
        store.deleteAll()
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)
    }
}
