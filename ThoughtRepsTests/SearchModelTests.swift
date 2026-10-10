import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("SearchModel")
struct SearchModelTests {
    let container: ModelContainer
    let store: ThoughtStore
    let index = SearchIndex(location: .inMemory)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway())
        store.searchIndex = index
        self.store = store
    }

    func model(_ scope: SearchScope = .all) -> SearchModel {
        SearchModel(scope: scope, index: index, context: container.mainContext)
    }

    @Test func shortQueriesClearResults() async {
        store.create(body: "alpha beta", now: now)
        let model = model()
        await model.search("alpha", debounce: .zero)
        #expect(model.rows.count == 1)
        await model.search("a", debounce: .zero)
        #expect(model.rows.isEmpty)
        #expect(model.loadedQuery == nil)
        await model.search("  b ", debounce: .zero)
        #expect(model.loadedQuery == nil)
    }

    @Test func rowsFollowResultOrder() async throws {
        let weak = store.create(body: "filler words and then banana at the end of a long body of text", now: now)
        let strong = store.create(body: "banana", now: now)
        let model = model()
        await model.search("banana", debounce: .zero)
        let expected = try await index.search("banana", scope: .all).map(\.id)
        #expect(model.rows.map(\.id) == expected)
        #expect(Set(model.rows.map(\.id)) == [weak.id, strong.id])
        #expect(model.loadedQuery == "banana")
    }

    @Test func missingThoughtsAreSkipped() async throws {
        let kept = store.create(body: "kiwi one", now: now)
        let gone = store.create(body: "kiwi two", now: now)
        container.mainContext.delete(gone)
        try container.mainContext.save()
        let model = model()
        await model.search("kiwi", debounce: .zero)
        #expect(model.rows.map(\.id) == [kept.id])
    }

    @Test func pagesInMoreWhenLastRowAppears() async throws {
        for number in 0..<(SearchModel.pageSize + 5) {
            store.create(body: "plum \(number)", now: now)
        }
        let model = model()
        await model.search("plum", debounce: .zero)
        #expect(model.rows.count == SearchModel.pageSize)
        await model.loadMoreIfNeeded(after: model.rows[0])
        #expect(model.rows.count == SearchModel.pageSize)
        await model.loadMoreIfNeeded(after: try #require(model.rows.last))
        #expect(model.rows.count == SearchModel.pageSize + 5)
        #expect(Set(model.rows.map(\.id)).count == SearchModel.pageSize + 5)
        await model.loadMoreIfNeeded(after: try #require(model.rows.last))
        #expect(model.rows.count == SearchModel.pageSize + 5)
    }

    @Test func scopeFiltersResults() async {
        let active = store.create(body: "fig active", now: now)
        let archived = store.create(body: "fig archived", now: now)
        store.archive(archived, now: now)
        let model = model(.archived)
        await model.search("fig", debounce: .zero)
        #expect(model.rows.map(\.id) == [archived.id])
        model.scope = .active
        await model.search("fig", debounce: .zero)
        #expect(model.rows.map(\.id) == [active.id])
    }

    @Test func cancelledSearchLeavesResultsAlone() async {
        store.create(body: "lime", now: now)
        let model = model()
        let task = Task { await model.search("lime", debounce: .seconds(5)) }
        task.cancel()
        await task.value
        #expect(model.rows.isEmpty)
        #expect(model.loadedQuery == nil)
    }

    @Test func removeDropsRow() async {
        let thought = store.create(body: "pear", now: now)
        let model = model()
        await model.search("pear", debounce: .zero)
        model.remove(id: thought.id)
        #expect(model.rows.isEmpty)
    }

    @Test func failedSearchIsAnErrorNotNoResults() async {
        let failing = SearchModel(scope: .all, context: container.mainContext) { _, _, _, _ in throw SearchTestError() }
        await failing.search("anything", debounce: .zero)
        #expect(failing.failed)
        #expect(failing.rows.isEmpty)
        #expect(failing.loadedQuery == "anything")
        await failing.search("a", debounce: .zero)
        #expect(!failing.failed)
    }

    @Test func failedPageLeavesPagingToRetry() async throws {
        for number in 0..<(SearchModel.pageSize + 5) {
            store.create(body: "plum \(number)", now: now)
        }
        let index = index
        let shouldFail = FailureFlag()
        let model = SearchModel(scope: .all, context: container.mainContext) { query, scope, limit, offset in
            if offset > 0 && shouldFail.value { throw SearchTestError() }
            return try await index.search(query, scope: scope, limit: limit, offset: offset)
        }
        await model.search("plum", debounce: .zero)
        shouldFail.value = true
        await model.loadMoreIfNeeded(after: try #require(model.rows.last))
        #expect(model.rows.count == SearchModel.pageSize)
        #expect(!model.failed)
        shouldFail.value = false
        await model.loadMoreIfNeeded(after: try #require(model.rows.last))
        #expect(model.rows.count == SearchModel.pageSize + 5)
    }

    @Test func pageFetchedForAnotherScopeIsDropped() async throws {
        for number in 0..<(SearchModel.pageSize + 5) {
            store.create(body: "plum \(number)", now: now)
        }
        let index = index
        let model = ScopeSwitcher.make(index: index, context: container.mainContext)
        await model.model.search("plum", debounce: .zero)
        model.armed.value = true
        await model.model.loadMoreIfNeeded(after: try #require(model.model.rows.last))
        #expect(model.model.rows.isEmpty)
        #expect(model.model.scope == .archived)
    }

    @Test func statusLabels() {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        func status(archived: Bool = false, pinned: Bool = false, dueAt: Date) -> SearchStatus? {
            SearchStatus.of(isArchived: archived, isPinned: pinned, nextDueAt: dueAt, now: noon)
        }
        func days(_ count: Int, hour: Int = 9) -> Date {
            let day = calendar.date(byAdding: .day, value: count, to: noon)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        #expect(status(archived: true, pinned: true, dueAt: noon) == .archived)
        #expect(status(pinned: true, dueAt: days(3)) == nil)
        #expect(status(dueAt: days(-1)) == .due)
        #expect(status(dueAt: noon) == .due)
        #expect(status(dueAt: days(0, hour: 18)) == .laterToday)
        #expect(status(dueAt: days(1)) == .backIn(days: 1))
        #expect(status(dueAt: days(3)) == .backIn(days: 3))
        #expect(SearchStatus.backIn(days: 1).text == "Back in 1 day")
        #expect(SearchStatus.backIn(days: 3).text == "Back in 3 days")
        #expect(SearchStatus.laterToday.text == "Back later today")
    }

    @Test func repeatedSearchKeepsLoadedPages() async throws {
        for number in 0..<(SearchModel.pageSize + 5) {
            store.create(body: "plum \(number)", now: now)
        }
        let model = model()
        await model.search("plum", debounce: .zero)
        await model.loadMoreIfNeeded(after: try #require(model.rows.last))
        #expect(model.rows.count == SearchModel.pageSize + 5)
        let ids = model.rows.map(\.id)
        await model.search("plum", debounce: .zero)
        #expect(model.rows.map(\.id) == ids)
        await model.search("plu", debounce: .zero)
        #expect(model.rows.count == SearchModel.pageSize)
    }

    @Test func pruneDropsDeletedAndOutOfScopeRows() async throws {
        let kept = store.create(body: "melon kept", now: now)
        let archived = store.create(body: "melon archived", now: now)
        let deleted = store.create(body: "melon deleted", now: now)
        let model = model(.active)
        await model.search("melon", debounce: .zero)
        #expect(model.rows.count == 3)
        store.archive(archived, now: now)
        store.delete(deleted, now: now)
        model.pruneRows()
        #expect(model.rows.map(\.id) == [kept.id])
    }
}

private struct SearchTestError: Error {}

private final class FailureFlag: @unchecked Sendable {
    var value = false
}

/// A model whose source switches the scope once `armed`, as if the user changed the filter mid-fetch.
@MainActor
private struct ScopeSwitcher {
    let model: SearchModel
    let armed: FailureFlag

    static func make(index: SearchIndex, context: ModelContext) -> ScopeSwitcher {
        let armed = FailureFlag()
        let holder = ModelHolder()
        let model = SearchModel(scope: .all, context: context) { query, scope, limit, offset in
            let results = try await index.search(query, scope: scope, limit: limit, offset: offset)
            if armed.value {
                await MainActor.run { holder.model?.scope = .archived }
            }
            return results
        }
        holder.model = model
        return ScopeSwitcher(model: model, armed: armed)
    }
}

@MainActor
private final class ModelHolder: @unchecked Sendable {
    var model: SearchModel?
}
