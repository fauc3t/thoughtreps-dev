import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// The per-group change clocks, tombstones, and the group-by-group import merge.
@MainActor
@Suite("Change clocks and tombstones")
struct ChangeClockTests {
    let container: ModelContainer
    let store: ThoughtStore
    let index = SearchIndex(location: .inMemory)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves, ratingPrompt: .throwaway()
        )
        store.searchIndex = index
        self.store = store
    }

    func makeSource() throws -> (container: ModelContainer, store: ThoughtStore) {
        let source = try ModelContainer.thoughtReps(inMemory: true)
        let sourceStore = ThoughtStore(
            context: source.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves, ratingPrompt: .throwaway()
        )
        return (source, sourceStore)
    }

    func exportFile(_ from: ModelContainer) throws -> URL {
        try BackupExporter(container: from, appVersion: "1.0", build: "1").export(now: at(1_000_000))
    }

    func planFor(_ file: URL) throws -> BackupPlan {
        try BackupImporter.plan(try BackupImporter.preflight(fileURL: file), container: container)
    }

    /// Plans the file against the store, then imports it the way `BackupModel` does.
    @discardableResult
    func importFile(_ url: URL) async throws -> BackupPlan {
        let plan = try planFor(url)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(store.importThoughts(batch.thoughts, tags: plan.preflight.tags, tally: &tally))
        }
        #expect(store.mergeTagColors(info: plan.preflight.tags))
        return plan
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func clocks(_ thought: Thought) -> [Date] {
        [thought.updatedAt, thought.scheduleChangedAt, thought.stateChangedAt]
    }

    func recordOf(_ thought: Thought) -> ThoughtRecord {
        ThoughtRecord(thought, hasImage: { _ in true })
    }

    func importRecord(_ record: ThoughtRecord, tags: [TagRecord] = []) -> ImportTally {
        var tally = ImportTally()
        #expect(store.importThoughts([ImportedThought(record: record, images: [:])], tags: tags, tally: &tally))
        return tally
    }

    func tombstones() throws -> [Tombstone] {
        try container.mainContext.fetch(FetchDescriptor<Tombstone>())
    }

    func checkClean() throws {
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    // MARK: Writers

    @Test func createStartsEveryClockAtCreation() {
        let thought = store.create(body: "# A", now: t0)
        #expect(clocks(thought) == [t0, t0, t0])
    }

    @Test func scheduleWritersBumpOnlyTheScheduleClock() {
        let thought = store.create(body: "# A", now: t0)
        store.markViewed(thought, now: at(10))
        #expect(clocks(thought) == [t0, at(10), t0])
        store.snooze(thought, days: 2, now: at(20))
        #expect(clocks(thought) == [t0, at(20), t0])
    }

    @Test func reviewBumpsOnlyTheScheduleClockAndRefusedReviewNone() {
        let thought = store.create(body: "# A", learn: true, now: t0)
        #expect(!store.review(thought, gotIt: true, now: t0))
        #expect(clocks(thought) == [t0, t0, t0])
        let due = at(3 * 86_400)
        #expect(store.review(thought, gotIt: true, now: due))
        #expect(clocks(thought) == [t0, due, t0])
    }

    @Test func intervalAndLearnModeBumpOnlyTheScheduleClock() {
        let thought = store.create(body: "# A", now: t0)
        store.setInterval(thought, days: 3, now: at(10))
        #expect(clocks(thought) == [t0, at(10), t0])
        store.setLearnMode(thought, true, now: at(20))
        #expect(clocks(thought) == [t0, at(20), t0])
        store.setLearnMode(thought, true, now: at(30))
        #expect(clocks(thought) == [t0, at(20), t0])
    }

    @Test func aLearnOpenLeavesTheScheduleClockAndAFixedOpenMovesIt() {
        let learning = store.create(body: "# L", learn: true, now: t0)
        store.markViewed(learning, now: at(10))
        #expect(clocks(learning) == [t0, t0, t0] && learning.viewCount == 1)
        let fixed = store.create(body: "# F", now: t0)
        store.markViewed(fixed, now: at(10))
        #expect(clocks(fixed) == [t0, at(10), t0] && fixed.viewCount == 1)
    }

    @Test func pinningWhenNothingChangesTouchesNoClock() {
        let thought = store.create(body: "# A", now: t0)
        store.setPinned(thought, false, now: at(10))
        #expect(clocks(thought) == [t0, t0, t0])
        store.archive(thought, now: at(20))
        store.setPinned(thought, true, now: at(30))
        #expect(clocks(thought) == [t0, t0, at(20)] && !thought.isPinned)
    }

    @Test func pinAndArchiveBumpOnlyTheStateClock() {
        let thought = store.create(body: "# A", now: t0)
        store.setPinned(thought, true, now: at(10))
        #expect(clocks(thought) == [t0, t0, at(10)])
        store.archive(thought, now: at(20))
        #expect(clocks(thought) == [t0, t0, at(20)])
    }

    @Test func restoreBumpsStateAndSchedule() {
        let thought = store.create(body: "# A", now: t0)
        store.archive(thought, now: at(10))
        store.restore(thought, now: at(20))
        #expect(clocks(thought) == [t0, at(20), at(20)])
    }

    @Test func editBumpsContentAndScheduleOnlyWhenTheIntervalChanges() {
        let thought = store.create(body: "# A", now: t0)
        store.update(thought, body: "# B", blocks: [], intervalDays: nil, now: at(10))
        #expect(clocks(thought) == [at(10), t0, t0])
        store.update(thought, body: "# B", blocks: [], intervalDays: 5, now: at(20))
        #expect(clocks(thought) == [at(20), at(20), t0])
    }

    @Test func tagColorBumpsTheTagClock() throws {
        store.create(body: "# A #swift", now: t0)
        let tag = try #require(try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        #expect(tag.updatedAt == .distantPast)
        #expect(store.setColor(tag, hex: "#3352D1", now: at(10)))
        #expect(tag.updatedAt == at(10))
        #expect(store.setColor(tag, hex: "#3352D1", now: at(20)))
        #expect(tag.updatedAt == at(10))
        #expect(!store.setColor(tag, hex: "nope", now: at(30)))
        #expect(tag.updatedAt == at(10))
    }

    // MARK: Tombstones

    @Test func deleteWritesATombstoneAndDeleteAllClearsThem() throws {
        let a = store.create(body: "# A", blocks: [BlockDraft(content: "x")], now: t0)
        let b = store.create(body: "# B", now: t0)
        let aID = a.id
        #expect(store.delete(a, now: at(5)))
        let found = try tombstones()
        #expect(found.count == 1 && found[0].id == aID && found[0].kind == "thought" && found[0].deletedAt == at(5))
        try checkClean()

        #expect(store.delete(b, now: at(6)))
        #expect(try tombstones().count == 2)
        store.create(body: "# C", now: at(7))
        #expect(store.deleteAll())
        #expect(try tombstones().isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Thought>()) == 0)
    }

    @Test func aFailedDeleteWritesNoTombstone() throws {
        var failing = store
        failing.save = { _ in throw InjectedSaveFailure() }
        let thought = store.create(body: "# A", now: t0)
        #expect(!failing.delete(thought, now: at(5)))
        #expect(try tombstones().isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Thought>()) == 1)
        try checkClean()
    }

    @Test func importingAThoughtRemovesItsTombstone() throws {
        let thought = store.create(body: "# A", now: t0)
        let saved = recordOf(thought)
        store.delete(thought, now: at(5))
        #expect(try tombstones().count == 1)
        #expect(importRecord(saved).added == 1)
        #expect(try tombstones().isEmpty)
        try checkClean()
    }

    @Test func tombstonesAreNotExported() throws {
        let a = store.create(body: "# A", now: t0)
        store.create(body: "# B", now: t0)
        store.delete(a, now: at(5))
        let file = try BackupExporter(container: container, appVersion: "1.0", build: "1").export(now: at(10))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preflight = try BackupImporter.preflight(fileURL: file)
        #expect(preflight.manifest.counts.thoughts == 1)
        #expect(Set(preflight.manifest.entries.keys) == [BackupFormat.tagsPath, BackupFormat.thoughtsPath])
    }

    @Test func checkerFlagsATombstoneForALiveThoughtAndDuplicates() throws {
        let thought = store.create(body: "# A", now: t0)
        let context = container.mainContext
        context.insert(Tombstone(id: thought.id, kind: .thought, deletedAt: t0))
        let stray = UUID()
        context.insert(Tombstone(id: stray, kind: .thought, deletedAt: t0))
        context.insert(Tombstone(id: stray, kind: .thought, deletedAt: t0))
        try context.save()
        let descriptions = try IntegrityChecker.check(context).map(\.description)
        #expect(descriptions.contains { $0.contains("matches a live thought") })
        #expect(descriptions.contains { $0.contains("Duplicate tombstone") })
    }

    // MARK: Import merge

    @Test func contentFromOneSideAndScheduleFromTheOther() throws {
        let thought = store.create(body: "# Original", now: t0)
        var incoming = recordOf(thought)
        // The other device edited the body later; this device snoozed later.
        incoming.body = "# Edited elsewhere"
        incoming.updatedAt = at(100)
        store.snooze(thought, days: 5, now: at(200))
        let snoozedDue = thought.nextDueAt

        let tally = importRecord(incoming)
        #expect(tally.replaced == 1)
        #expect(thought.body == "# Edited elsewhere" && thought.updatedAt == at(100))
        #expect(thought.nextDueAt == snoozedDue && thought.scheduleChangedAt == at(200))
        try checkClean()
    }

    @Test func scheduleFromTheFileWinsWhenNewerAndContentStays() throws {
        let thought = store.create(body: "# Mine", now: t0)
        store.update(thought, body: "# Mine v2", blocks: [], intervalDays: nil, now: at(100))
        var incoming = recordOf(thought)
        incoming.body = "# Theirs"
        incoming.updatedAt = at(50)
        incoming.nextDueAt = at(999_999)
        incoming.viewCount = 4
        incoming.lastViewedAt = at(60)
        incoming.scheduleChangedAt = at(300)

        #expect(importRecord(incoming).replaced == 1)
        #expect(thought.body == "# Mine v2" && thought.updatedAt == at(100))
        #expect(thought.nextDueAt == at(999_999) && thought.viewCount == 4 && thought.scheduleChangedAt == at(300))
        try checkClean()
    }

    @Test func anArchiveHereSurvivesAnOlderStateInTheFile() throws {
        let thought = store.create(body: "# A", now: t0)
        let older = recordOf(thought)
        store.archive(thought, now: at(100))

        #expect(importRecord(older).upToDate == 1)
        #expect(thought.isArchived && thought.stateChangedAt == at(100))
        try checkClean()
    }

    @Test func newerStateFromTheFileWinsAndPinnedNeverMeetsArchived() throws {
        let thought = store.create(body: "# A", now: t0)
        store.setPinned(thought, true, now: at(50))
        var incoming = recordOf(thought)
        incoming.isPinned = false
        incoming.isArchived = true
        incoming.archivedAt = at(100)
        incoming.stateChangedAt = at(100)

        #expect(importRecord(incoming).replaced == 1)
        #expect(thought.isArchived && !thought.isPinned && thought.archivedAt == at(100) && thought.stateChangedAt == at(100))
        try checkClean()
    }

    @Test func aPinLaterHereKeepsTheNewerSideOfEachGroup() throws {
        let thought = store.create(body: "# A", now: t0)
        var incoming = recordOf(thought)
        incoming.isArchived = true
        incoming.archivedAt = at(100)
        incoming.stateChangedAt = at(100)
        incoming.body = "# Newer body"
        incoming.updatedAt = at(100)
        store.setPinned(thought, true, now: at(200))

        _ = importRecord(incoming)
        #expect(thought.isPinned && !thought.isArchived)
        #expect(thought.body == "# Newer body")
        try checkClean()
    }

    @Test func sameFileTwiceChangesNothing() throws {
        let thought = store.create(body: "# A", now: t0)
        var incoming = recordOf(thought)
        incoming.scheduleChangedAt = at(10)
        incoming.nextDueAt = at(5_000)
        #expect(importRecord(incoming).replaced == 1)
        let tally = importRecord(incoming)
        #expect(tally.replaced == 0 && tally.added == 0 && tally.upToDate == 1)
    }

    @Test func tagColorFollowsTheNewerTagClock() throws {
        let thought = store.create(body: "# A #swift #work", now: t0)
        let tags = try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>())
        let swift = try #require(tags.first { $0.name == "swift" })
        let work = try #require(tags.first { $0.name == "work" })
        store.setColor(swift, hex: "#111111", now: at(100))
        store.setColor(work, hex: "#222222", now: at(100))
        let info = [
            TagRecord(name: "swift", displayName: "swift", colorHex: "#AAAAAA", updatedAt: at(200)),
            TagRecord(name: "work", displayName: "work", colorHex: "#BBBBBB", updatedAt: at(50)),
        ]
        _ = importRecord(recordOf(thought), tags: info)
        #expect(swift.colorHex == "#AAAAAA" && swift.updatedAt == at(200))
        #expect(work.colorHex == "#222222" && work.updatedAt == at(100))
        try checkClean()
    }

    @Test func learnOpenHereAndGotItThereKeepsBothWithMaxCounters() throws {
        let thought = store.create(body: "# L", learn: true, now: t0)
        var opened = recordOf(thought)
        opened.viewCount = 1
        opened.lastViewedAt = at(50)
        let due = at(3 * 86_400)
        store.review(thought, gotIt: true, now: due)
        let reviewedDue = thought.nextDueAt
        let gap = thought.learnIntervalDays

        #expect(importRecord(opened).replaced == 1)
        #expect(thought.nextDueAt == reviewedDue && thought.learnIntervalDays == gap && thought.scheduleChangedAt == due)
        #expect(thought.viewCount == 1 && thought.lastViewedAt == at(50))
        try checkClean()
    }

    @Test func countersMergeByMaxWhicheverSideWinsTheSchedule() throws {
        let thought = store.create(body: "# F", now: t0)
        store.markViewed(thought, now: at(10))
        store.markViewed(thought, now: at(20))
        var incoming = recordOf(thought)
        incoming.viewCount = 1
        incoming.lastViewedAt = at(30)
        incoming.nextDueAt = at(40 * 86_400)
        incoming.scheduleChangedAt = at(30)
        #expect(importRecord(incoming).replaced == 1)
        #expect(thought.nextDueAt == at(40 * 86_400) && thought.scheduleChangedAt == at(30))
        #expect(thought.viewCount == 2 && thought.lastViewedAt == at(30))
        try checkClean()
    }

    @Test func aNilLastViewedLosesToAnyDate() throws {
        let thought = store.create(body: "# F", now: t0)
        var incoming = recordOf(thought)
        incoming.viewCount = 1
        incoming.lastViewedAt = at(5)
        #expect(importRecord(incoming).replaced == 1)
        #expect(thought.viewCount == 1 && thought.lastViewedAt == at(5))
        #expect(importRecord(recordOf(thought)).upToDate == 1)
        try checkClean()
    }

    @Test func tagsCreatedFromTextNeverBeatAChosenColor() throws {
        let thought = store.create(body: "# A #swift", now: at(500))
        let swift = try #require(try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        #expect(swift.updatedAt == .distantPast)
        _ = importRecord(
            recordOf(thought),
            tags: [TagRecord(name: "swift", displayName: "swift", colorHex: "#AAAAAA", updatedAt: at(10))]
        )
        #expect(swift.colorHex == "#AAAAAA")
    }

    @Test func tagRecordsWithoutAClockAreTheOldest() throws {
        let thought = store.create(body: "# A #swift", now: t0)
        let swift = try #require(try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        store.setColor(swift, hex: "#111111", now: at(100))
        _ = importRecord(recordOf(thought), tags: [TagRecord(name: "swift", displayName: "swift", colorHex: "#AAAAAA")])
        #expect(swift.colorHex == "#111111")
    }

    // MARK: Old format

    @Test func recordsWithoutTheNewFieldsFallBackToUpdatedAt() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","body":"# Old","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z",\
        "nextDueAt":"2026-01-08T00:00:00Z","viewCount":0,"intervalModeRaw":"fixed","isPinned":false,"isArchived":false,\
        "tags":[],"blocks":[],"images":[]}
        """
        let decoded = try BackupFormat.decoder().decode(ThoughtRecord.self, from: Data(json.utf8))
        #expect(decoded.scheduleChangedAt == nil && decoded.stateChangedAt == nil)
        #expect(decoded.scheduleClock == decoded.updatedAt && decoded.stateClock == decoded.updatedAt)
        #expect(decoded.isImportable)

        #expect(importRecord(decoded).added == 1)
        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<Thought>()).first)
        #expect(stored.scheduleChangedAt == decoded.updatedAt && stored.stateChangedAt == decoded.updatedAt)

        let tag = try BackupFormat.decoder().decode(TagRecord.self, from: Data(#"{"name":"a","displayName":"a"}"#.utf8))
        #expect(tag.updatedAt == nil && tag.updatedClock == .distantPast)
        try checkClean()
    }

    @Test func clocksSurviveAnExportAndImport() async throws {
        let thought = store.create(body: "# A #swift", now: t0)
        store.snooze(thought, days: 2, now: at(10))
        store.setPinned(thought, true, now: at(20))
        let file = try BackupExporter(container: container, appVersion: "1.0", build: "1").export(now: at(30))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let other = try ModelContainer.thoughtReps(inMemory: true)
        let otherStore = ThoughtStore(
            context: other.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves
        )
        let preflight = try BackupImporter.preflight(fileURL: file)
        let plan = try BackupImporter.plan(preflight, container: other)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(otherStore.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        let copy = try #require(try other.mainContext.fetch(FetchDescriptor<Thought>()).first)
        #expect(clocks(copy) == [t0, at(10), at(20)])
        let tag = try #require(try other.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        #expect(tag.updatedAt == .distantPast)
    }

    // MARK: Plan

    @Test func planCountsScheduleStateAndCounterDifferences() async throws {
        let (source, sourceStore) = try makeSource()
        let fixed = sourceStore.create(body: "# Fixed #swift", now: t0)
        let learning = sourceStore.create(body: "# Learn", learn: true, now: at(1))
        let first = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        try await importFile(first)
        let identical = try planFor(first)
        #expect(identical.toImport.isEmpty && identical.newerTags == 0 && identical.upToDate == 2)

        sourceStore.snooze(fixed, days: 3, now: at(100))
        let scheduleFile = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: scheduleFile.deletingLastPathComponent()) }
        let schedule = try planFor(scheduleFile)
        #expect(schedule.newer == 1 && schedule.toImport == [fixed.id])
        try await importFile(scheduleFile)

        sourceStore.setPinned(learning, true, now: at(200))
        let stateFile = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: stateFile.deletingLastPathComponent()) }
        let state = try planFor(stateFile)
        #expect(state.newer == 1 && state.toImport == [learning.id])
        try await importFile(stateFile)

        sourceStore.markViewed(learning, now: at(300))
        #expect(learning.scheduleChangedAt == at(1))
        let counterFile = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: counterFile.deletingLastPathComponent()) }
        let counters = try planFor(counterFile)
        #expect(counters.newer == 1 && counters.toImport == [learning.id])
        try await importFile(counterFile)
        let learningID = learning.id
        let copy = try #require(try container.mainContext.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == learningID })).first)
        #expect(copy.viewCount == 1 && copy.lastViewedAt == at(300))
        #expect(try planFor(counterFile).toImport.isEmpty)
    }

    @Test func aTagColorOnlyFileIsPlannedAndMerged() async throws {
        let (source, sourceStore) = try makeSource()
        sourceStore.create(body: "# A #swift", now: t0)
        let first = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        try await importFile(first)
        let swift = try #require(try source.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        sourceStore.setColor(swift, hex: "#3352D1", now: at(300))
        let second = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        let plan = try planFor(second)
        #expect(plan.toImport.isEmpty && plan.upToDate == 1 && plan.newerTags == 1)
        #expect(store.mergeTagColors(info: plan.preflight.tags))
        let local = try #require(try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        #expect(local.colorHex == "#3352D1" && local.updatedAt == at(300))
    }

    @Test func duplicateIDsInOneFileDeliverTheRecordWithTheStampedClocks() async throws {
        let id = UUID()
        var older = record(id: id, body: "# Dup", createdAt: t0, updatedAt: at(10))
        older.scheduleChangedAt = at(10)
        var newer = older
        newer.updatedAt = at(20)
        newer.body = "# Dup newest"
        newer.scheduleChangedAt = at(20)
        var sameUpdate = older
        sameUpdate.scheduleChangedAt = at(500)
        var thoughts = Data()
        for item in [older, newer, sameUpdate] {
            thoughts += try BackupFormat.encoder().encode(item) + Data("\n".utf8)
        }
        let hashes = [BackupFormat.tagsPath: sha256Hex(Data()), BackupFormat.thoughtsPath: sha256Hex(thoughts)]
        let manifest = try BackupFormat.encoder().encode(BackupManifest(
            format: BackupFormat.identifier, formatVersion: 1, appVersion: "1", build: "1", exportedAt: t0,
            counts: .init(thoughts: 3, tags: 0, images: 0), entries: hashes
        ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClockDup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dup.thoughtreps")
        try writeArchive(
            [
                ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .none),
                ArchiveEntry(path: "manifest.json", data: manifest),
                ArchiveEntry(path: BackupFormat.tagsPath, data: Data(), method: .none),
                ArchiveEntry(path: BackupFormat.thoughtsPath, data: thoughts, method: .none),
            ],
            to: url
        )

        try await importFile(url)
        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<Thought>()).first)
        #expect(stored.body == "# Dup newest" && stored.updatedAt == at(20) && stored.scheduleChangedAt == at(20))
        try checkClean()
    }

    // MARK: Failures and search

    @Test func aFailedNonContentMergeLeavesTheThoughtAsItWasAndAnotherImportFinishes() throws {
        let thought = store.create(body: "# A", now: t0)
        var incoming = recordOf(thought)
        incoming.nextDueAt = at(9_999)
        incoming.scheduleChangedAt = at(50)
        incoming.isArchived = true
        incoming.archivedAt = at(50)
        incoming.stateChangedAt = at(50)
        let due = thought.nextDueAt

        var failing = store
        failing.save = { _ in throw InjectedSaveFailure() }
        var tally = ImportTally()
        #expect(!failing.importThoughts([ImportedThought(record: incoming, images: [:])], tags: [], tally: &tally))
        #expect(thought.nextDueAt == due && !thought.isArchived && clocks(thought) == [t0, t0, t0])
        try checkClean()

        #expect(importRecord(incoming).replaced == 1)
        #expect(thought.isArchived && thought.nextDueAt == at(9_999))
        try checkClean()
    }

    @Test func aFailedTagColorMergeChangesNothing() throws {
        store.create(body: "# A #swift", now: t0)
        let swift = try #require(try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        var failing = store
        failing.save = { _ in throw InjectedSaveFailure() }
        let info = [TagRecord(name: "swift", displayName: "swift", colorHex: "#AAAAAA", updatedAt: at(10))]
        #expect(!failing.mergeTagColors(info: info))
        #expect(swift.colorHex == nil && swift.updatedAt == .distantPast)
        #expect(store.mergeTagColors(info: info))
        #expect(swift.colorHex == "#AAAAAA")
        try checkClean()
    }

    @Test func aStateOnlyWinReindexes() async throws {
        let thought = store.create(body: "# Reindex me", now: t0)
        #expect(try await index.search("reindex", scope: .active).map(\.id) == [thought.id])
        var incoming = recordOf(thought)
        incoming.isArchived = true
        incoming.archivedAt = at(50)
        incoming.stateChangedAt = at(50)

        #expect(importRecord(incoming).replaced == 1)
        #expect(try await index.search("reindex", scope: .active).isEmpty)
        #expect(try await index.search("reindex", scope: .archived).map(\.id) == [thought.id])
        #expect(try await SearchIndexChecker.check(container.mainContext, index: index).isEmpty)
    }
}
