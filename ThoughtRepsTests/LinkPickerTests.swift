import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Link picker")
struct LinkPickerTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let store: ThoughtStore
    let isolated = IsolatedDefaults()
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves, ratingPrompt: RatingPrompt.throwaway()
        )
    }

    func links(of thought: Thought) -> [UUID] {
        thought.sortedBlocks.filter { $0.kind == .thoughtLink }.compactMap(\.linkedThoughtID)
    }

    @Test func filterDropsExcludedAndArchivedThoughts() {
        let editing = store.create(body: "# Editing", now: now)
        let linked = store.create(body: "# Linked", now: now)
        let archived = store.create(body: "# Archived", now: now)
        let free = store.create(body: "# Free", now: now)
        store.archive(archived, now: now)

        let excluded: Set<UUID> = [editing.id, linked.id]
        let result = [editing, linked, archived, free].filter { LinkPicker.isEligible($0, excluding: excluded) }
        #expect(result.map(\.id) == [free.id])
    }

    @Test func recentsAreNewestFirstLimitedAndSkipExcludedAndArchived() {
        var made: [Thought] = []
        for index in 0..<25 {
            made.append(store.create(body: "# T\(index)", now: now.addingTimeInterval(Double(index) * 60)))
        }
        let newest = made[24], second = made[23], archived = made[22]
        store.archive(archived, now: now.addingTimeInterval(9_999))

        let recents = ThoughtCounts.recentForPicker(excluding: [newest.id], in: context)
        #expect(recents.count == ThoughtCounts.recentPickerLimit)
        #expect(recents.first?.id == second.id)
        #expect(!recents.contains { $0.id == newest.id || $0.id == archived.id })
        #expect(recents.map(\.updatedAt) == recents.map(\.updatedAt).sorted(by: >))
    }

    @Test func aLinkDraftOnANewThoughtCreatesTheBlock() {
        let target = store.create(body: "# Target", now: now)
        let hub = store.create(
            body: "# Hub", blocks: [BlockDraft(kind: .thoughtLink, linkedThoughtID: target.id)], now: now
        )
        #expect(links(of: hub) == [target.id])
    }

    @Test func addingAndRemovingALinkDraftOnAnExistingThoughtSavesThroughUpdate() {
        let target = store.create(body: "# Target", now: now)
        let hub = store.create(body: "# Hub", blocks: [BlockDraft(content: "text")], now: now)
        var drafts = BlockDraft.drafts(for: hub)
        drafts.append(BlockDraft(kind: .thoughtLink, linkedThoughtID: target.id))

        #expect(store.update(hub, body: "# Hub", blocks: drafts, images: [], intervalDays: nil, now: now.addingTimeInterval(60)))
        #expect(links(of: hub) == [target.id])

        drafts.removeAll { $0.kind == .thoughtLink }
        #expect(store.update(hub, body: "# Hub", blocks: drafts, images: [], intervalDays: nil, now: now.addingTimeInterval(120)))
        #expect(links(of: hub).isEmpty)
        #expect(hub.sortedBlocks.count == 1)
    }

    // MARK: Filtered paging

    /// A source over `ids` in order, as an index would page them.
    func source(over ids: [UUID]) -> SearchModel.Source {
        { _, _, limit, offset in
            ids.dropFirst(offset).prefix(limit).map {
                SearchResult(id: $0, isArchived: false, matchedField: .body, snippet: "x")
            }
        }
    }

    func makeThoughts(_ count: Int) -> [Thought] {
        (0..<count).map { store.create(body: "# T\($0)", now: now.addingTimeInterval(Double($0))) }
    }

    @Test func aFullPageWhoseLastResultIsExcludedStillPages() async {
        let thoughts = makeThoughts(130)
        let hidden = thoughts[49].id
        let model = SearchModel(scope: .all, context: context, isIncluded: { $0.id != hidden }, source: source(over: thoughts.map(\.id)))
        await model.search("tt", debounce: .zero)
        #expect(model.rows.count == 99)
        #expect(!model.rows.contains { $0.id == hidden })
        await model.loadMoreIfNeeded(after: model.rows.last!)
        #expect(model.rows.count == 129)
    }

    @Test func aFullyExcludedPageKeepsLoadingInsteadOfShowingEmpty() async {
        let thoughts = makeThoughts(70)
        let hidden = Set(thoughts.prefix(50).map(\.id))
        let model = SearchModel(scope: .all, context: context, isIncluded: { !hidden.contains($0.id) }, source: source(over: thoughts.map(\.id)))
        await model.search("tt", debounce: .zero)
        #expect(model.rows.count == 20)
    }

    @Test func morePagesLoadWhenTheFilteredPageIsShort() async {
        let thoughts = makeThoughts(130)
        let hidden = Set(thoughts.prefix(30).map(\.id))
        let model = SearchModel(scope: .all, context: context, isIncluded: { !hidden.contains($0.id) }, source: source(over: thoughts.map(\.id)))
        await model.search("tt", debounce: .zero)
        #expect(model.rows.count == 70)
        await model.loadMoreIfNeeded(after: model.rows.last!)
        #expect(model.rows.count == 100)
    }

    @Test func withoutAFilterEveryResultShowsAndPagingIsUnchanged() async {
        let thoughts = makeThoughts(70)
        let model = SearchModel(scope: .all, context: context, source: source(over: thoughts.map(\.id)))
        await model.search("tt", debounce: .zero)
        #expect(model.rows.count == SearchModel.pageSize)
        await model.loadMoreIfNeeded(after: model.rows.last!)
        #expect(model.rows.count == 70)
    }
}
