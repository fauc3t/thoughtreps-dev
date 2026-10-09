import Foundation
import Observation
import OSLog
import SwiftData

/// Runs a debounced, paged search against `SearchIndex` and loads just the visible page's thoughts.
@MainActor
@Observable
final class SearchModel {
    struct Row: Identifiable {
        let thought: Thought
        let result: SearchResult
        var id: UUID { result.id }
    }

    typealias Source = @Sendable (_ query: String, _ scope: SearchScope, _ limit: Int, _ offset: Int) async throws -> [SearchResult]

    static let minimumLength = 2
    static let pageSize = 50

    /// Changing it clears the rows, so rows from the old scope can't be tapped while the new search waits.
    var scope: SearchScope {
        didSet { if scope != oldValue { clear() } }
    }
    private(set) var rows: [Row] = []
    /// The trimmed query `rows` belongs to, or `nil` when there is no completed search.
    private(set) var loadedQuery: String?
    /// True when the last first-page search failed.
    private(set) var failed = false

    private var loadedScope: SearchScope?
    private let source: Source
    private let context: ModelContext
    private var nextOffset = 0
    private var hasMore = false
    private var isLoadingMore = false

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "search")

    convenience init(scope: SearchScope, index: SearchIndex = .shared, context: ModelContext) {
        self.init(scope: scope, context: context) { query, scope, limit, offset in
            try await index.search(query, scope: scope, limit: limit, offset: offset)
        }
    }

    init(scope: SearchScope, context: ModelContext, source: @escaping Source) {
        self.scope = scope
        self.source = source
        self.context = context
    }

    static func isSearchable(_ text: String) -> Bool {
        trimmed(text).count >= minimumLength
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the results with the first page for `text`, unless they already hold the results
    /// for this query and scope, so a view that reappears keeps its loaded pages. Waits `debounce` first, so a task
    /// cancelled by newer input never reaches the index. Under two characters it clears the results.
    func search(_ text: String, debounce: Duration = .milliseconds(150)) async {
        let query = Self.trimmed(text)
        guard query.count >= Self.minimumLength else {
            clear()
            return
        }
        if query == loadedQuery, scope == loadedScope, !failed { return }
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
        }
        guard !Task.isCancelled else { return }
        let requestedScope = scope
        let page = try? await fetchPage(query, scope: requestedScope, offset: 0)
        guard !Task.isCancelled, requestedScope == scope else { return }
        failed = page == nil
        rows = page?.rows ?? []
        nextOffset = Self.pageSize
        hasMore = page?.count == Self.pageSize
        loadedQuery = query
        loadedScope = requestedScope
    }

    /// Appends the next page once `row` is the last one shown. A failed page leaves `hasMore`
    /// set, so the next time the last row appears it tries again.
    func loadMoreIfNeeded(after row: Row) async {
        guard hasMore, !isLoadingMore, row.id == rows.last?.id,
              let query = loadedQuery, let requestedScope = loadedScope
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await fetchPage(query, scope: requestedScope, offset: nextOffset),
              !Task.isCancelled, query == loadedQuery, requestedScope == loadedScope
        else { return }
        let known = Set(rows.map(\.id))
        rows += page.rows.filter { !known.contains($0.id) }
        nextOffset += Self.pageSize
        hasMore = page.count == Self.pageSize
    }

    /// `rows` without thoughts deleted, or moved out of the scope, since the page loaded.
    var liveRows: [Row] {
        rows.filter { row in
            guard !row.thought.isDeleted, row.thought.modelContext != nil else { return false }
            switch scope {
            case .active: return !row.thought.isArchived
            case .archived: return row.thought.isArchived
            case .all: return true
            }
        }
    }

    /// Drops rows whose thoughts were deleted or left the scope since they loaded. The kept
    /// thoughts are live objects, so their edits already show.
    func pruneRows() {
        rows = liveRows
    }

    /// Drops a row whose thought the caller just deleted or moved.
    func remove(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    private func clear() {
        rows = []
        loadedQuery = nil
        loadedScope = nil
        failed = false
        nextOffset = 0
        hasMore = false
    }

    /// `count` is the number of index results, which can exceed `rows.count` when thoughts are missing.
    private func fetchPage(_ query: String, scope: SearchScope, offset: Int) async throws -> (rows: [Row], count: Int) {
        let results: [SearchResult]
        do {
            results = try await source(query, scope, Self.pageSize, offset)
        } catch {
            Self.logger.error("Search failed: \(error)")
            throw error
        }
        return (try thoughtRows(for: results), results.count)
    }

    private func thoughtRows(for results: [SearchResult]) throws -> [Row] {
        let ids = results.map(\.id)
        let descriptor = FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) })
        let thoughts: [Thought]
        do {
            thoughts = try context.fetch(descriptor)
        } catch {
            Self.logger.error("Search result fetch failed: \(error)")
            throw error
        }
        let byID = Dictionary(thoughts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return results.compactMap { result in
            byID[result.id].map { Row(thought: $0, result: result.showing(title: $0.title)) }
        }
    }
}
