import Foundation
import SQLite3
import Testing
@testable import ThoughtReps

func searchDocument(
    _ body: String, id: UUID = UUID(), archived: Bool = false, updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
    blocks: String = "", titles: String = "", tags: String = ""
) -> SearchDocument {
    SearchDocument(id: id, updatedAt: updatedAt, isArchived: archived, body: body, blocks: blocks, titles: titles, tags: tags)
}

@Suite("SearchIndex")
struct SearchIndexTests {
    let index = SearchIndex(location: .inMemory)

    func ids(_ input: String, scope: SearchScope = .active, limit: Int = 50, offset: Int = 0) async throws -> [UUID] {
        try await index.search(input, scope: scope, limit: limit, offset: offset).map(\.id)
    }

    @Test func insertUpdateRemove() async throws {
        let doc = searchDocument("Remember the milk")
        await index.upsert([doc])
        #expect(try await ids("milk") == [doc.id])
        #expect(await index.count == 1)

        var edited = doc
        edited.body = "Remember the bread"
        await index.upsert([edited])
        #expect(try await ids("milk").isEmpty)
        #expect(try await ids("bread") == [doc.id])
        #expect(await index.count == 1)

        await index.remove(ids: [doc.id])
        #expect(try await ids("bread").isEmpty)
        #expect(await index.count == 0)
    }

    @Test func submittedChangesApplyInOrderBeforeAnySearch() async throws {
        let id = UUID()
        index.submit(.upsert(searchDocument("first", id: id)))
        index.submit(.upsert(searchDocument("second", id: id)))
        index.submit(.setFingerprint(id, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), isArchived: true))
        #expect(try await ids("first", scope: .all).isEmpty)
        #expect(try await ids("second", scope: .archived) == [id])
        index.submit(.remove(id))
        index.submit(.upsert(searchDocument("third", id: id)))
        #expect(try await ids("third") == [id])
        index.submit(.removeAll)
        #expect(await index.count == 0)
    }

    @Test func matchingIgnoresCaseAndAccents() async throws {
        let doc = searchDocument("Un caf\u{E9} \u{C0} Paris, na\u{EF}ve \u{C9}TUDE")
        await index.upsert([doc])
        for query in ["CAFE", "cafe", "caf\u{E9}", "cafe\u{301}", "naive", "etude", "A paris"] {
            #expect(try await ids(query) == [doc.id], "query \(query)")
        }
    }

    @Test func wordsMatchByPrefixOnly() async throws {
        let doc = searchDocument("Programming in Swift")
        await index.upsert([doc])
        #expect(try await ids("prog") == [doc.id])
        #expect(try await ids("s") == [doc.id])
        #expect(try await ids("gramming").isEmpty)
    }

    @Test func everyWordMustMatch() async throws {
        let both = searchDocument("apples and oranges")
        let one = searchDocument("apples only")
        await index.upsert([both, one])
        #expect(try await ids("apple orange") == [both.id])
        #expect(Set(try await ids("apple")) == [both.id, one.id])
    }

    @Test func hostileInputIsHarmless() async throws {
        await index.upsert([searchDocument("plain text")])
        for query in ["\"", "\"\"\"", "* OR *", "text\" OR \"", "NEAR(a b)", "(", "col:text", "-text", "\u{E000}"] {
            _ = try await ids(query)
        }
        #expect(try await ids("").isEmpty)
    }

    @Test func scopeSeparatesActiveFromArchived() async throws {
        let active = searchDocument("shared word")
        let archived = searchDocument("shared word", archived: true)
        await index.upsert([active, archived])
        #expect(try await ids("shared", scope: .active) == [active.id])
        #expect(try await ids("shared", scope: .archived) == [archived.id])
        #expect(Set(try await ids("shared", scope: .all)) == [active.id, archived.id])
        let result = try await index.search("shared", scope: .all).first { $0.id == archived.id }
        #expect(result?.isArchived == true)

        index.submit(.setFingerprint(active.id, updatedAt: active.updatedAt, isArchived: true))
        #expect(try await ids("shared", scope: .active).isEmpty)
    }

    @Test func pagingWalksThroughAllResultsOnce() async throws {
        let docs = (0..<25).map { searchDocument("note \($0)", updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double($0))) }
        await index.upsert(docs)
        var seen: [UUID] = []
        for offset in stride(from: 0, to: 30, by: 10) {
            seen += try await ids("note", limit: 10, offset: offset)
        }
        #expect(seen.count == 25)
        #expect(Set(seen).count == 25)
        #expect(try await ids("note", limit: 10, offset: 25).isEmpty)
    }

    @Test func rankingPrefersDenserMatchesThenNewer() async throws {
        let sparse = searchDocument("alpha " + String(repeating: "filler ", count: 40))
        let dense = searchDocument("alpha alpha alpha")
        let oldTie = searchDocument("beta", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newTie = searchDocument("beta", updatedAt: Date(timeIntervalSince1970: 2_000))
        await index.upsert([sparse, dense, oldTie, newTie])
        #expect(try await ids("alpha") == [dense.id, sparse.id])
        #expect(try await ids("beta") == [newTie.id, oldTie.id])
    }

    @Test func matchedFieldAndSnippetComeFromTheFieldThatMatched() async throws {
        let doc = searchDocument(
            "A plain body", blocks: "Hidden secret passphrase", titles: "Vacation photos", tags: "travel"
        )
        await index.upsert([doc])
        let secret = try await #require(index.search("passphrase").first)
        #expect(secret.matchedField == .blockText)
        #expect(SearchSnippet.plain(secret.snippet).contains("passphrase"))
        #expect(secret.snippet.contains("\u{E000}passphrase\u{E001}"))
        #expect(try await index.search("vacation").first?.matchedField == .blockTitle)
        #expect(try await index.search("travel").first?.matchedField == .tag)
        #expect(try await index.search("plain").first?.matchedField == .body)
    }

    @Test func snippetsAreSingleLine() async throws {
        await index.upsert([searchDocument("one\ntwo needle\nthree")])
        let result = try await #require(index.search("needle").first)
        #expect(!result.snippet.contains("\n"))
    }

    @Test func snippetNearTheTopDoesNotRepeatTheTitle() async throws {
        let doc = searchDocument(SearchText.plain("# Evening pages\nThree pages, no editing. Reflection tends to show up around page two."))
        await index.upsert([doc])
        let result = try await #require(index.search("reflection").first)
        #expect(result.snippet == "Three pages, no editing. \u{E000}Reflection\u{E001} tends to show up around page two.")
        #expect(!SearchSnippet.plain(result.snippet).contains("Evening"))
    }

    @Test func titleOnlyMatchShowsTheStartOfThePreview() async throws {
        let doc = searchDocument("Evening pages\nThree pages, no editing.")
        await index.upsert([doc])
        let result = try await #require(index.search("evening").first)
        #expect(result.snippet == "Three pages, no editing.")
    }

    @Test func titleOnlyThoughtKeepsTheTitleMatch() async throws {
        await index.upsert([searchDocument("Evening pages")])
        let result = try await #require(index.search("evening").first)
        #expect(result.snippet == "\u{E000}Evening\u{E001} pages")
    }

    @Test func titleMatchPrefersAMatchInAnotherField() async throws {
        await index.upsert([searchDocument("Evening pages\nThree pages", tags: "evening")])
        let result = try await #require(index.search("evening").first)
        #expect(result.matchedField == .tag)
    }

    @Test func deepMatchKeepsItsWindowAndNoHeadingBodyIsUnchanged() async throws {
        let filler = String(repeating: "filler ", count: 40)
        let deep = searchDocument("Title line\n\(filler)needle \(filler)")
        let flat = searchDocument("- first needle item\nsecond line")
        await index.upsert([deep, flat])
        let deepResult = try await #require(index.search("needle").first { $0.id == deep.id })
        #expect(deepResult.snippet.hasPrefix("…") && deepResult.snippet.contains("\u{E000}needle\u{E001}"))
        #expect(!SearchSnippet.plain(deepResult.snippet).contains("Title"))
    }

    @Test func droppingTheTitleLineKeepsMarkersPaired() {
        #expect(SearchSnippet.droppingTitleLine(from: "Title\nrest \u{E000}hit\u{E001}") == "rest \u{E000}hit\u{E001}")
        #expect(SearchSnippet.droppingTitleLine(from: "\u{E000}a\nb\u{E001} rest") == "\u{E000}b\u{E001} rest")
        #expect(SearchSnippet.droppingTitleLine(from: "…mid\nrest") == "…mid\nrest")
        #expect(SearchSnippet.droppingTitleLine(from: "no newline") == "no newline")
    }

    @Test func snippetBecomesAttributedStringWithBoldMatches() {
        let attributed = SearchSnippet.attributed("\u{2026}the \u{E000}quick\u{E001} brown \u{E000}fox\u{E001}")
        #expect(String(attributed.characters) == "\u{2026}the quick brown fox")
        let bold = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
        #expect(bold == ["quick", "fox"])
        #expect(String(SearchSnippet.attributed("no markers").characters) == "no markers")
        #expect(SearchSnippet.attributed("").characters.isEmpty)
    }

    @Test func markersInThoughtTextAreStripped() async throws {
        let doc = searchDocument("odd \u{E000}text\u{E001} here")
        #expect(doc.body == "odd text here")
    }

    @Test func documentTextDropsMarkdownAndImageTokens() {
        let image = ImageToken.token(for: UUID())
        let plain = SearchText.plain("# Title\n- **bold** item \(image)\n```swift\nlet x = 1\n```\n[link](https://example.com) #tag")
        #expect(plain == "Title\nbold item\nlet x = 1\nlink #tag")
        #expect(!plain.contains("img:"))
    }

    @Test func entriesAndDocumentsRoundTrip() async throws {
        let doc = searchDocument("body text", archived: true, updatedAt: Date(timeIntervalSince1970: 1_790_000_123.456), blocks: "b", titles: "t", tags: "x")
        await index.upsert([doc])
        #expect(await index.document(for: doc.id) == doc)
        #expect(await index.entries()[doc.id] == SearchIndexEntry(updatedAt: doc.updatedAt, isArchived: true))
    }

    // MARK: File handling

    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "search-\(UUID().uuidString)", directoryHint: .isDirectory).appending(path: "index.sqlite")
    }

    @Test func fileIndexPersistsAndIsExcludedFromBackup() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let doc = searchDocument("persisted")
        await SearchIndex(location: .file(url)).upsert([doc])
        let reopened = SearchIndex(location: .file(url))
        #expect(try await reopened.search("persisted").map(\.id) == [doc.id])
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func damagedFileIsReplacedByAnEmptyIndex() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        let rebuilt = SearchIndex(location: .file(url))
        #expect(await rebuilt.count == 0)
        let doc = searchDocument("works again")
        await rebuilt.upsert([doc])
        #expect(try await rebuilt.search("again").map(\.id) == [doc.id])
    }

    @Test func otherSchemaVersionIsReplacedByAnEmptyIndex() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await SearchIndex(location: .file(url)).upsert([searchDocument("old")])
        let raw = try SQLiteDatabase(path: url.path)
        try raw.execute("PRAGMA user_version = 99")
        let reopened = SearchIndex(location: .file(url))
        #expect(await reopened.count == 0)
        await reopened.upsert([searchDocument("new")])
        #expect(await reopened.count == 1)
    }

    // MARK: Performance

    @Test func queriesStayFastAtTwoHundredThousandThoughts() async throws {
        let vocabulary = (0..<3000).map { "word\($0)x" } + ["swift", "idea", "review", "note", "thought", "project", "meeting", "book"]
        var rng = SeededGenerator(seed: 42)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rare = "zebrafish"
        let docs = (0..<200_000).map { n -> SearchDocument in
            var words = (0..<24).map { _ in vocabulary.randomElement(using: &rng)! }
            if n == 123_456 { words.append(rare) }
            return searchDocument(words.joined(separator: " "), archived: n % 10 == 0, updatedAt: base.addingTimeInterval(Double(n)))
        }
        let seedStart = ContinuousClock.now
        await index.upsert(docs)
        print("search perf: seeded 200k rows in \(ContinuousClock.now - seedStart)")
        #expect(await index.count == 200_000)

        for query in [rare, "swift", "swi", "sw", "swift idea", "w", "word12 review note"] {
            let start = ContinuousClock.now
            let results = try await index.search(query, scope: .active, limit: 50)
            let elapsed = ContinuousClock.now - start
            print("search perf: '\(query)' -> \(results.count) results in \(elapsed)")
            #expect(elapsed < .seconds(1), "query '\(query)' took \(elapsed)")
        }
        #expect(try await ids(rare).count == 1)
    }
}
