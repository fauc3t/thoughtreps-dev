import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import ThoughtReps

func fakeFile(_ tag: UInt8 = 1, name: String = "notes.pdf", type: String = "com.adobe.pdf") -> FileDraft {
    let data = Data([tag, 1, 2])
    return FileDraft(filename: name, typeIdentifier: type, byteCount: data.count, thumbnailData: Data([tag]), data: data)
}

func fileBlock(_ file: FileDraft) -> BlockDraft {
    BlockDraft(kind: .file, file: file)
}

@MainActor
@Suite("File blocks in the store")
struct FileBlockTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let container: ModelContainer
    let context: ModelContext
    let index = SearchIndex(location: .inMemory)
    let isolated = IsolatedDefaults()

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        context = container.mainContext
    }

    func makeStore(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> ThoughtStore {
        var store = ThoughtStore(
            context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: save,
            pendingImageSaves: isolated.pendingImageSaves
        )
        store.searchIndex = index
        return store
    }

    func fileCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<FileAsset>())
    }

    func expectClean(_ comment: Comment? = nil) throws {
        #expect(try IntegrityChecker.check(context).map(\.description) == [])
    }

    @Test func createStoresTheFileWithItsMetadata() throws {
        let draft = fakeFile(7, name: "report.pdf")
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(draft)], now: now)
        #expect(thought.modelContext != nil)
        let block = try #require(thought.sortedBlocks.first)
        #expect(block.kind == .file)
        let file = try #require(block.file)
        #expect(file.id == draft.id)
        #expect(file.filename == "report.pdf")
        #expect(file.typeIdentifier == "com.adobe.pdf")
        #expect(file.byteCount == 3)
        #expect(file.data == draft.data)
        #expect(file.thumbnailData == draft.thumbnailData)
        #expect(file.thought === thought)
        #expect(thought.files?.count == 1)
        try expectClean()
    }

    @Test func createSanitizesTheFilename() throws {
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(fakeFile(name: "../a/b:c.txt"))], now: now)
        #expect(thought.sortedBlocks.first?.file?.filename == "_a_b_c.txt")
        try expectClean()
    }

    @Test func oversizeFilesAreDropped() throws {
        let big = Data(count: FileAttachment.maxBytes + 1)
        let draft = FileDraft(filename: "big.bin", typeIdentifier: "public.data", byteCount: big.count, thumbnailData: nil, data: big)
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(draft)], now: now)
        #expect(thought.modelContext != nil)
        #expect(thought.blocks?.isEmpty == true)
        #expect(try fileCount() == 0)

        let exact = Data(count: FileAttachment.maxBytes)
        let atLimit = FileDraft(filename: "ok.bin", typeIdentifier: "public.data", byteCount: exact.count, thumbnailData: nil, data: exact)
        let other = makeStore().create(body: "# Doc 2", blocks: [fileBlock(atLimit)], now: now)
        #expect(other.sortedBlocks.first?.file?.byteCount == FileAttachment.maxBytes)
        try expectClean()
    }

    @Test func processorRefusesOversizeFiles() throws {
        #expect(throws: FileProcessingError.tooLarge) {
            try FileProcessor.process(data: Data(count: FileAttachment.maxBytes + 1), filename: "big.bin")
        }
        let draft = try FileProcessor.process(data: Data("hello".utf8), filename: "a/b.txt")
        #expect(draft.filename == "a_b.txt")
        #expect(draft.typeIdentifier == UTType.plainText.identifier)
        #expect(draft.byteCount == 5)
        #expect(FileAttachment.tooLargeMessage == "Files can be up to 5 MB.")
    }

    @Test func fileBlockWithoutBytesIsDropped() throws {
        let missing = FileDraft(filename: "ghost.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 3, thumbnailData: nil, data: nil)
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(missing), BlockDraft(kind: .file)], now: now)
        #expect(thought.blocks?.isEmpty == true)
        try expectClean()
    }

    @Test func updateAddsAndKeepsAndRemovesFiles() throws {
        let store = makeStore()
        let thought = store.create(body: "# Doc", blocks: [BlockDraft(content: "text")], now: now)
        let first = fakeFile(1, name: "one.pdf")
        let later = now.addingTimeInterval(60)
        #expect(store.update(thought, body: "# Doc", blocks: BlockDraft.drafts(for: thought) + [fileBlock(first)], intervalDays: nil, now: later))
        #expect(thought.updatedAt == later)
        #expect(thought.sortedBlocks.map(\.kind) == [.markdown, .file])
        let blockID = try #require(thought.sortedBlocks.last?.id)

        let second = fakeFile(2, name: "two.pdf")
        #expect(store.update(thought, body: "# Doc", blocks: BlockDraft.drafts(for: thought) + [fileBlock(second)], intervalDays: nil, now: later.addingTimeInterval(60)))
        #expect(thought.sortedBlocks.map(\.kind) == [.markdown, .file, .file])
        #expect(thought.sortedBlocks[1].id == blockID)
        #expect(thought.sortedBlocks[1].file?.id == first.id)
        #expect(thought.sortedBlocks[2].file?.id == second.id)
        #expect(try fileCount() == 2)
        try expectClean()

        let remaining = BlockDraft.drafts(for: thought).filter { $0.file?.id != first.id }
        let removedAt = later.addingTimeInterval(120)
        #expect(store.update(thought, body: "# Doc", blocks: remaining, intervalDays: nil, now: removedAt))
        #expect(thought.updatedAt == removedAt)
        #expect(thought.sortedBlocks.map(\.kind) == [.markdown, .file])
        #expect(thought.sortedBlocks.last?.file?.id == second.id)
        #expect(thought.sortedBlocks.map(\.order) == [0, 1])
        #expect(try fileCount() == 1)
        #expect(thought.files?.count == 1)
        try expectClean()
    }

    @Test func updateKeepsStoredFileBytesWhateverTheDraftSays() throws {
        let store = makeStore()
        let draft = fakeFile(5)
        let thought = store.create(body: "# Doc", blocks: [fileBlock(draft)], now: now)
        var drafts = BlockDraft.drafts(for: thought)
        drafts[0].file?.data = Data([9, 9, 9, 9])
        store.update(thought, body: "# Doc", blocks: drafts, intervalDays: nil, now: now.addingTimeInterval(10))
        #expect(thought.sortedBlocks.first?.file?.data == draft.data)
        try expectClean()
    }

    @Test func repeatedFileIDsAreStoredOnce() throws {
        let draft = fakeFile(3)
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(draft), fileBlock(draft)], now: now)
        #expect(thought.blocks?.count == 1)
        #expect(try fileCount() == 1)
        try expectClean()
    }

    @Test func removingAMarkdownBlockDoesNotTouchFiles() throws {
        let store = makeStore()
        let thought = store.create(body: "# Doc", blocks: [BlockDraft(content: "text"), fileBlock(fakeFile(1))], now: now)
        let drafts = BlockDraft.drafts(for: thought).filter { $0.kind == .file }
        store.update(thought, body: "# Doc", blocks: drafts, intervalDays: nil, now: now.addingTimeInterval(1))
        #expect(thought.sortedBlocks.map(\.kind) == [.file])
        #expect(try fileCount() == 1)
        try expectClean()
    }

    @Test func deleteRemovesFiles() throws {
        let store = makeStore()
        let thought = store.create(body: "# Doc", blocks: [fileBlock(fakeFile(1)), fileBlock(fakeFile(2))], now: now)
        let keep = store.create(body: "# Keep", blocks: [fileBlock(fakeFile(3))], now: now)
        #expect(try fileCount() == 3)
        #expect(store.delete(thought, now: now))
        #expect(try fileCount() == 1)
        #expect(keep.files?.count == 1)
        #expect(store.deleteAll())
        #expect(try fileCount() == 0)
        try expectClean()
    }

    @Test func failedSaveLeavesNoFile() throws {
        let thought = makeStore().create(body: "# Doc", now: now)
        let failing = makeStore(save: { _ in throw InjectedSaveFailure() })
        #expect(!failing.update(thought, body: "# Doc", blocks: [fileBlock(fakeFile(1))], intervalDays: nil, now: now.addingTimeInterval(1)))
        #expect(try fileCount() == 0)
        let detached = failing.create(body: "# New", blocks: [fileBlock(fakeFile(2))], now: now)
        #expect(detached.modelContext == nil)
        #expect(try fileCount() == 0)
        try expectClean()
    }

    @Test func failedRemovalKeepsTheFile() throws {
        let store = makeStore()
        let thought = store.create(body: "# Doc", blocks: [fileBlock(fakeFile(1))], now: now)
        let failing = makeStore(save: { _ in throw InjectedSaveFailure() })
        #expect(!failing.update(thought, body: "# Doc", blocks: [], intervalDays: nil, now: now.addingTimeInterval(1)))
        #expect(try fileCount() == 1)
        #expect(thought.sortedBlocks.first?.file != nil)
        try expectClean()
    }

    // MARK: Search

    @Test func searchFindsTheFilename() async throws {
        let store = makeStore()
        let thought = store.create(body: "# Tax papers", blocks: [fileBlock(fakeFile(1, name: "invoice-2026.pdf"))], now: now)
        #expect(try await index.search("invoice", scope: .all).map(\.id) == [thought.id])
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty)

        store.update(thought, body: "# Tax papers", blocks: [], intervalDays: nil, now: now.addingTimeInterval(1))
        #expect(try await index.search("invoice", scope: .all).isEmpty)
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty)
    }

    // MARK: Integrity

    @Test func integrityCheckerCatchesBadFiles() throws {
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(fakeFile(1))], now: now)
        let file = try #require(thought.sortedBlocks.first?.file)
        #expect(try IntegrityChecker.check(context).isEmpty)

        file.byteCount = 99
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("byteCount") })
        file.byteCount = 3

        file.data = nil
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("missing its data") })
        file.data = Data([1, 1, 2])

        file.filename = "a/b"
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("filename") })
        file.filename = "ok.pdf"
        #expect(try IntegrityChecker.check(context).isEmpty)

        let block = try #require(thought.sortedBlocks.first)
        block.kindRaw = BlockKind.markdown.rawValue
        let violations = try IntegrityChecker.check(context).map(\.description)
        #expect(violations.contains { $0.contains("not a file block") })
        #expect(violations.contains { $0.contains("Non-file block") })
        block.kindRaw = BlockKind.file.rawValue

        let second = FileAsset(data: Data([1]), thumbnailData: nil, filename: "two.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 1)
        context.insert(second)
        second.thought = thought
        second.block = block
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("has 2 files") })
        second.thought = nil
        second.block = nil
        context.delete(second)
        #expect(try IntegrityChecker.check(context).isEmpty)

        let orphan = FileAsset(data: Data([1]), thumbnailData: nil, filename: "orphan.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 1)
        context.insert(orphan)
        let orphanViolations = try IntegrityChecker.check(context).map(\.description)
        #expect(orphanViolations.contains { $0.contains("has no thought") })
        context.delete(orphan)

        let strayBlock = Block(kind: .file, content: "", order: 1)
        context.insert(strayBlock)
        strayBlock.thought = thought
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("has 0 files") })
        context.delete(strayBlock)
    }

    // MARK: Names and Quick Look

    @Test func filenamesAreSanitized() {
        #expect(FileAttachment.sanitizedFilename("report.pdf") == "report.pdf")
        #expect(FileAttachment.sanitizedFilename("a/b\\c:d.txt") == "a_b_c_d.txt")
        #expect(FileAttachment.sanitizedFilename("..") == "File")
        #expect(FileAttachment.sanitizedFilename("  ") == "File")
        #expect(FileAttachment.sanitizedFilename(".env") == "env")
        #expect(FileAttachment.sanitizedFilename("tab\there.txt") == "tab_here.txt")
        let long = String(repeating: "a", count: 300) + ".pdf"
        let cut = FileAttachment.sanitizedFilename(long)
        #expect(cut.utf8.count == FileAttachment.maxFilenameBytes)
        #expect(cut.hasSuffix(".pdf"))
        let cjk = FileAttachment.sanitizedFilename(String(repeating: "\u{6587}", count: 200) + ".txt")
        #expect(cjk.utf8.count <= FileAttachment.maxFilenameBytes)
        #expect(cjk.hasSuffix(".txt"))
        #expect(cjk.dropLast(4).allSatisfy { $0 == "\u{6587}" })
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let emoji = FileAttachment.sanitizedFilename(String(repeating: family, count: 40) + ".png")
        #expect(emoji.utf8.count <= FileAttachment.maxFilenameBytes)
        #expect(emoji.hasSuffix(".png"))
        #expect(emoji.dropLast(4).allSatisfy { String($0) == family })
    }

    @Test func quickLookCopiesKeepTheNameAndAreRemoved() throws {
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(fakeFile(1, name: "my file.pdf"))], now: now)
        let file = try #require(thought.sortedBlocks.first?.file)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = try QuickLookFiles.prepare(file, in: temporary)
        #expect(url.lastPathComponent == "my file.pdf")
        #expect(try Data(contentsOf: url) == file.data)
        QuickLookFiles.remove(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try QuickLookFiles.prepare(file, in: temporary)
        QuickLookFiles.removeAll(in: temporary)
        #expect(!FileManager.default.fileExists(atPath: QuickLookFiles.root(in: temporary).path))
    }

    @Test func cardDescribesTheFile() throws {
        let thought = makeStore().create(body: "# Doc", blocks: [fileBlock(fakeFile(1, name: "slides.pdf"))], now: now)
        let model = FileCardModel(try #require(thought.sortedBlocks.first?.file))
        #expect(model.symbolName == "doc.richtext")
        #expect(model.subtitle.contains(ByteCountFormatter.string(fromByteCount: 3, countStyle: .file)))
        #expect(model.accessibilityLabel.hasPrefix("File: slides.pdf"))
        // Only the first letter is raised, so the acronym keeps its case.
        #expect(model.typeDescription == "PDF document")
        #expect(FileCardModel(FileDraft(filename: "x", typeIdentifier: "nonsense", byteCount: 1, thumbnailData: nil, data: nil)).symbolName == "doc")
    }

    @Test func droppedProvidersAreClassified() {
        func provider(_ type: UTType) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
            return provider
        }
        #expect(FileIntake.isDroppedFile(provider(.pdf)))
        #expect(FileIntake.isDroppedFile(provider(.zip)))
        #expect(!FileIntake.isDroppedFile(provider(.png)))
        #expect(!FileIntake.isDroppedFile(provider(.plainText)))
        #expect(!FileIntake.isDroppedFile(provider(.url)))
    }
}
