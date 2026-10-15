import Foundation
import SwiftData
import os

/// Queues for pushing whatever the store has that `SyncState` doesn't show as synced, off the main
/// thread. "Not in sync.sqlite" means "not uploaded yet", so turning sync on queues everything. Reads
/// the store with a context of its own, a page of thoughts at a time and only the id and clock fields.
/// The fingerprint check is drift detection only: a change that doesn't move a clock isn't seen here,
/// which is why the engine pushes every outbox entry and compares base hashes.
@ModelActor
actor SyncReconciler {
    struct Summary: Sendable, Equatable {
        var thoughts = 0
        var tags = 0
        var settings = 0
        /// Thoughts whose deletion isn't recorded as synced.
        var deletions = 0
        /// For tests: the scan must never run on the main thread.
        var ranOnMainThread = false

        var total: Int { thoughts + tags + settings + deletions }
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")
    private static let pageSize = 1000

    private nonisolated static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    private struct ThoughtClocks {
        var id: UUID
        var updatedAt: Date
        var scheduleChangedAt: Date
        var stateChangedAt: Date
        var viewCount: Int
        var lastViewedAt: Date?
    }

    /// The page of thoughts after `last` in id order (keyset paging, so a delete mid-scan skips nothing
    /// and the cost doesn't grow with the offset). A fresh context per page keeps memory flat.
    private func clocks(after last: UUID?) throws -> [ThoughtClocks] {
        let context = ModelContext(modelContainer)
        var page = FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.id)])
        if let last { page.predicate = #Predicate { $0.id > last } }
        page.propertiesToFetch = [\.id, \.updatedAt, \.scheduleChangedAt, \.stateChangedAt, \.viewCount, \.lastViewedAt]
        page.fetchLimit = Self.pageSize
        return try context.fetch(page).map {
            ThoughtClocks(
                id: $0.id, updatedAt: $0.updatedAt, scheduleChangedAt: $0.scheduleChangedAt,
                stateChangedAt: $0.stateChangedAt, viewCount: $0.viewCount, lastViewedAt: $0.lastViewedAt
            )
        }
    }

    private func tombstones(after last: UUID?) throws -> [(id: UUID, deletedAt: Date)] {
        let context = ModelContext(modelContainer)
        let kind = TombstoneKind.thought.rawValue
        var page = FetchDescriptor<Tombstone>(predicate: #Predicate { $0.kind == kind }, sortBy: [SortDescriptor(\.id)])
        if let last { page.predicate = #Predicate { $0.kind == kind && $0.id > last } }
        page.fetchLimit = Self.pageSize
        return try context.fetch(page).map { ($0.id, $0.deletedAt) }
    }

    /// Does nothing while sync is off. Each page of thoughts (and of tombstones) is queued as soon as it is scanned, so a
    /// write made meanwhile (which queues itself) is never undone, only possibly queued twice.
    func reconcile(state: SyncState, settings: SettingsRecord) async throws -> Summary {
        var summary = Summary()
        summary.ranOnMainThread = Self.isOnMainThread()
        guard state.isEnabled else { return summary }

        var last: UUID?
        while true {
            let page = try clocks(after: last)
            let ids = page.map(\.id.uuidString)
            let content = try await state.fingerprints(type: .thoughtContent, entityIDs: ids)
            let meta = try await state.fingerprints(type: .thoughtMeta, entityIDs: ids)
            let stale = page.filter {
                let id = $0.id.uuidString
                return content[id] != SyncFingerprint.content(updatedAt: $0.updatedAt)
                    || meta[id] != SyncFingerprint.meta(
                        scheduleChangedAt: $0.scheduleChangedAt, stateChangedAt: $0.stateChangedAt,
                        viewCount: $0.viewCount, lastViewedAt: $0.lastViewedAt
                    )
            }
            state.enqueue(stale.map { .thought($0.id) })
            summary.thoughts += stale.count
            guard page.count == Self.pageSize else { break }
            last = page.last?.id
        }

        last = nil
        while true {
            let page = try tombstones(after: last)
            let ids = page.map(\.id.uuidString)
            let content = try await state.fingerprints(type: .thoughtContent, entityIDs: ids)
            let meta = try await state.fingerprints(type: .thoughtMeta, entityIDs: ids)
            let unsynced = page.filter {
                let id = $0.id.uuidString
                let fingerprint = SyncFingerprint.deletion(deletedAt: $0.deletedAt)
                return content[id] != fingerprint || meta[id] != fingerprint
            }
            state.enqueue(unsynced.map { .thought($0.id) })
            summary.deletions += unsynced.count
            guard page.count == Self.pageSize else { break }
            last = page.last?.id
        }

        // Tags are few, so one fetch.
        let tags = try ModelContext(modelContainer).fetch(FetchDescriptor<Tag>())
        let tagFingerprints = try await state.fingerprints(type: .tag, entityIDs: tags.map(\.name))
        let staleTags = tags.filter { tagFingerprints[$0.name] != SyncFingerprint.tag(updatedAt: $0.updatedAt) }
        state.enqueue(staleTags.map { .tag($0.name) })
        summary.tags = staleTags.count

        let synced = try await state.fingerprints(type: .settings, entityIDs: [SyncEntity.settingsID])
        if synced[SyncEntity.settingsID] != SyncFingerprint.settings(changedAt: settings.changedAt) {
            state.enqueue([.settings])
            summary.settings = 1
        }

        await state.flush()
        Self.logger.info("Sync reconciled: \(summary.thoughts) thoughts, \(summary.tags) tags, \(summary.deletions) deletions, \(summary.settings) settings queued")
        return summary
    }
}

/// Runs the reconciler in the background. A call made while one is running waits for it and then runs its own pass,
/// so whoever asked can rely on everything written before the call being queued.
@MainActor
enum SyncReconcileRunner {
    private static var running: Task<SyncReconciler.Summary?, Never>?

    /// Never throws: a failure is logged and the next launch tries again.
    @discardableResult
    static func reconcile(container: ModelContainer, state: SyncState = .shared) async -> SyncReconciler.Summary? {
        guard state.isEnabled else { return nil }
        while let running { _ = await running.value }
        let settings = SettingsRecord.current()
        let task = Task { () -> SyncReconciler.Summary? in
            defer { running = nil }
            do {
                // Built in a detached task so the actor's context isn't created on the main thread.
                return try await Task.detached {
                    try await SyncReconciler(modelContainer: container).reconcile(state: state, settings: settings)
                }.value
            } catch {
                Logger(subsystem: "com.thoughtreps", category: "sync").error("Sync reconciliation failed: \(error)")
                return nil
            }
        }
        running = task
        return await task.value
    }
}
