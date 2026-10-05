import Foundation
import Observation
import SwiftData
import os

/// Brings the search index in line with the store, off the main thread. Reads the store with a
/// context of its own, `id`, `updatedAt` and `isArchived` a page at a time, and loads whole
/// thoughts only for the ones whose row is missing or out of date.
@ModelActor
actor SearchReconciler {
    struct Summary: Sendable, Equatable {
        var added = 0
        var updated = 0
        var removed = 0
        /// For tests: the scan must never run on the main thread.
        var ranOnMainThread = false
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "search")
    private static let pageSize = 1000
    private static let loadSize = 200

    private var announced = false

    private nonisolated static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    private func announce(_ onWork: @Sendable () async -> Void) async {
        guard !announced else { return }
        announced = true
        await onWork()
    }

    /// Reads one page of fingerprints. A fresh context per page keeps memory flat, and sorting by
    /// id makes the offsets stable.
    private func fingerprints(offset: Int) throws -> [(id: UUID, entry: SearchIndexEntry)] {
        let context = ModelContext(modelContainer)
        var page = FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.id)])
        page.propertiesToFetch = [\.id, \.updatedAt, \.isArchived]
        page.fetchOffset = offset
        page.fetchLimit = Self.pageSize
        return try context.fetch(page).map { ($0.id, SearchIndexEntry(updatedAt: $0.updatedAt, isArchived: $0.isArchived)) }
    }

    /// Documents for `ids`, read in a context of their own that is dropped afterwards, with blocks
    /// and tags prefetched rather than faulted per thought.
    private func documents(for ids: [UUID]) throws -> [SearchDocument] {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.relationshipKeyPathsForPrefetching = [\.blocks, \.tags]
        return try context.fetch(descriptor).map { SearchDocument($0) }
    }

    private func ids(presentAmong ids: [UUID]) throws -> Set<UUID> {
        let context = ModelContext(modelContainer)
        var lookup = FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) })
        lookup.propertiesToFetch = [\.id]
        return Set(try context.fetch(lookup).map(\.id))
    }

    private func load(_ ids: [UUID], seen: [UUID: SearchIndexEntry], into index: SearchIndex, onWork: @Sendable () async -> Void) async throws {
        await announce(onWork)
        let documents = try documents(for: ids)
        await index.upsert(documents.map { ($0, expected: seen[$0.id]) })
    }

    /// `onWork` is called once, before the first row is written, if anything needs fixing. Rows are
    /// written only if the index still holds what the scan saw, so an edit made while this runs wins.
    func reconcile(index: SearchIndex, onWork: @Sendable () async -> Void) async throws -> Summary {
        var summary = Summary()
        summary.ranOnMainThread = Self.isOnMainThread()
        let seen = await index.entries()
        var known = seen
        announced = false
        var stale: [UUID] = []

        var offset = 0
        while true {
            let thoughts = try fingerprints(offset: offset)
            for (id, current) in thoughts {
                if let entry = known.removeValue(forKey: id) {
                    // Equal fingerprints are taken as equal text; a write that left `updatedAt` unchanged goes unnoticed.
                    guard entry != current else { continue }
                    summary.updated += 1
                } else {
                    summary.added += 1
                }
                stale.append(id)
                if stale.count >= Self.loadSize {
                    try await load(stale, seen: seen, into: index, onWork: onWork)
                    stale.removeAll()
                }
            }
            if thoughts.count < Self.pageSize { break }
            offset += Self.pageSize
        }
        if !stale.isEmpty { try await load(stale, seen: seen, into: index, onWork: onWork) }

        // Rows the scan didn't meet are checked against the store before removal: the scan can miss a
        // thought that was written while it ran.
        var gone: [(UUID, SearchIndexEntry)] = []
        let leftovers = Array(known.keys)
        for start in stride(from: 0, to: leftovers.count, by: Self.loadSize) {
            let batch = Array(leftovers[start..<min(start + Self.loadSize, leftovers.count)])
            let present = try ids(presentAmong: batch)
            gone += batch.filter { !present.contains($0) }.map { ($0, seen[$0]!) }
        }
        if !gone.isEmpty {
            await announce(onWork)
            summary.removed = await index.remove(gone)
        }
        Self.logger.info("Search index reconciled: \(summary.added) added, \(summary.updated) updated, \(summary.removed) removed")
        return summary
    }
}

/// What the Search screen reads to show "Indexing…".
@MainActor
@Observable
final class SearchIndexStatus {
    static let shared = SearchIndexStatus()

    /// True while reconciliation is fixing rows. Results may be incomplete until it clears.
    private(set) var isIndexing = false
    /// True once a reconciliation has finished since launch.
    private(set) var isReconciled = false
    private var isReconciling = false

    /// Compares the index with the store in the background and fixes it. Returns when done.
    /// Never throws: a failure is logged and the index stays as it was.
    func reconcile(container: ModelContainer, index: SearchIndex = .shared) async {
        guard !isReconciling else { return }
        isReconciling = true
        defer {
            isReconciling = false
            isIndexing = false
        }
        do {
            // Built in a detached task so the actor's context isn't created on the main thread.
            _ = try await Task.detached {
                try await SearchReconciler(modelContainer: container).reconcile(index: index) { [self] in
                    await MainActor.run { isIndexing = true }
                }
            }.value
            isReconciled = true
        } catch {
            Logger(subsystem: "com.thoughtreps", category: "search").error("Search reconciliation failed: \(error)")
        }
    }
}
