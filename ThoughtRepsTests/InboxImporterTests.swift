import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("InboxImporter")
struct InboxImporterTests {
    let container: ModelContainer
    let dir: URL
    let defaults: UserDefaults
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "InboxImporterTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    func store(failingSave: Bool = false) -> ThoughtStore {
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        if failingSave { store.save = { _ in throw CocoaError(.fileWriteUnknown) } }
        return store
    }

    func importer(removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> InboxImporter {
        InboxImporter(defaults: defaults, removeFile: removeFile)
    }

    var rememberedIDs: [String] { defaults.stringArray(forKey: InboxImporter.importedIDsKey) ?? [] }

    @discardableResult
    func drop(_ body: String, at date: Date) throws -> InboxItem {
        let item = InboxItem(id: UUID(), body: body, createdAt: date)
        try Inbox.write(item, to: dir)
        return item
    }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func thoughts() throws -> [Thought] {
        try container.mainContext.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    @Test func importCreatesThoughtsAndDeletesFiles() throws {
        let created = t0.addingTimeInterval(-3 * 86_400)
        try drop("Hello #swift", at: created)
        let count = importer().importPending(from: dir, store: store())
        #expect(count == 1)
        let thought = try #require(try thoughts().first)
        #expect(thought.body == "Hello #swift")
        #expect(thought.createdAt == created)
        #expect(thought.nextDueAt == Scheduler.adding(days: 7, to: created, calendar: .current))
        #expect(thought.tags?.map(\.name) == ["swift"])
        #expect(try files().isEmpty)
        #expect(rememberedIDs.isEmpty)
    }

    @Test func unreadableFileIsLeftInPlace() throws {
        let unreadable = dir.appendingPathComponent("\(UUID().uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try drop("Fine", at: t0)
        #expect(importer().importPending(from: dir, store: store()) == 1)
        #expect(try files() == [unreadable.lastPathComponent])
    }

    @Test func undecodableFileIsDeleted() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(importer().importPending(from: dir, store: store()) == 0)
        #expect(try files().isEmpty)
    }

    @Test func failedSaveKeepsFile() throws {
        try drop("Keep me", at: t0)
        let failing = store(failingSave: true)
        let count = importer().importPending(from: dir, store: failing)
        #expect(count == 0)
        #expect(failing.saveErrors.message?.contains("Couldn't import a shared thought.") == true)
        #expect(failing.saveErrors.note == nil)
        #expect(try files().count == 1)
        #expect(try thoughts().isEmpty)
        #expect(importer().importPending(from: dir, store: store()) == 1)
        #expect(try files().isEmpty)
    }

    @Test func failedCreateStopsTheRunAndKeepsLaterFiles() throws {
        try drop("first", at: t0)
        try drop("second", at: t0.addingTimeInterval(1))
        try drop("third", at: t0.addingTimeInterval(2))
        var calls = 0
        var flaky = store()
        flaky.save = { context in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }
        #expect(importer().importPending(from: dir, store: flaky) == 1)
        #expect(calls == 2)
        #expect(try thoughts().map(\.body) == ["first"])
        #expect(try files().count == 2)

        #expect(importer().importPending(from: dir, store: store()) == 2)
        #expect(try thoughts().map(\.body) == ["first", "second", "third"])
        #expect(try files().isEmpty)
    }

    @Test func failedDeleteDoesNotDuplicateOnNextRun() throws {
        let item = try drop("Once", at: t0)
        let stuck = importer(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(stuck.importPending(from: dir, store: store()) == 1)
        #expect(try files().count == 1)
        #expect(rememberedIDs == [item.id.uuidString])

        #expect(importer().importPending(from: dir, store: store()) == 0)
        #expect(try thoughts().count == 1)
        #expect(try files().isEmpty)
        #expect(rememberedIDs.isEmpty)
    }

    @Test func rememberedIDsWithoutFilesArePruned() throws {
        defaults.set([UUID().uuidString], forKey: InboxImporter.importedIDsKey)
        importer().importPending(from: dir, store: store())
        #expect(rememberedIDs.isEmpty)
    }

    @Test func corruptJSONIsDeletedAndOthersIgnored() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("note.txt"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("x.tmp"))
        try drop("Good", at: t0)
        #expect(importer().importPending(from: dir, store: store()) == 1)
        #expect(try thoughts().count == 1)
        #expect(try files() == ["note.txt", "x.tmp"])
    }

    @Test func importsOldestFirst() throws {
        try drop("second", at: t0.addingTimeInterval(10))
        try drop("third", at: t0.addingTimeInterval(20))
        try drop("first", at: t0)
        #expect(recordedOrder() == ["first", "second", "third"])
    }

    @Test func importsMillisecondsApartInOrder() throws {
        try drop("b", at: t0.addingTimeInterval(0.010))
        try drop("a", at: t0)
        try drop("c", at: t0.addingTimeInterval(0.020))
        #expect(recordedOrder() == ["a", "b", "c"])
    }

    func recordedOrder() -> [String] {
        var order: [String] = []
        var recording = store()
        recording.save = { context in
            order.append(contentsOf: context.insertedModelsArray.compactMap { ($0 as? Thought)?.body })
            try context.save()
        }
        importer().importPending(from: dir, store: recording)
        return order
    }

    @Test func missingDirectoryImportsNothing() {
        let missing = dir.appendingPathComponent("nope")
        #expect(importer().importPending(from: missing, store: store()) == 0)
    }

    @Test func itemRoundTripsWithMilliseconds() throws {
        let item = InboxItem(id: UUID(), body: "Body\nwith #tag", createdAt: t0.addingTimeInterval(0.123))
        let data = try InboxItem.encoder().encode(item)
        let decoded = try InboxItem.decoder().decode(InboxItem.self, from: data)
        #expect(decoded.id == item.id)
        #expect(decoded.body == item.body)
        #expect(abs(decoded.createdAt.timeIntervalSince(item.createdAt)) < 0.0005)
    }

    @Test func writeLeavesNoTempFile() throws {
        let item = try drop("x", at: t0)
        #expect(try files() == ["\(item.id.uuidString).json"])
    }

    @Test func directoryURLThrowsWithoutGroupKey() {
        #expect(throws: Inbox.InboxError.self) {
            try Inbox.directoryURL(bundle: Bundle(for: BundleToken.self))
        }
    }

    @Test func mergesTextAndURL() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(SharedContent.merge(text: "Note", url: url) == "Note\nhttps://example.com/a")
        #expect(SharedContent.merge(text: "See https://example.com/a", url: url) == "See https://example.com/a")
        #expect(SharedContent.merge(text: nil, url: url) == "https://example.com/a")
        #expect(SharedContent.merge(text: "  Just text \n", url: nil) == "Just text")
        #expect(SharedContent.merge(text: nil, url: nil) == "")
    }
}

private final class BundleToken {}
