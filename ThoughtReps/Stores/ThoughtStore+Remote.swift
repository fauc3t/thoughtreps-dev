import Foundation
import SwiftData
import os

extension ThoughtStore {
    /// Applies what one pulled page says: the import merge (`execute`, per group, with the sync tie-breaks
    /// of `RemoteMerge`), plus remote deletions, tag records and the settings record.
    ///
    /// - Content that differs from the local thought replaces it when the thought has no unpushed change
    ///   (`contentBaseHash`), and otherwise goes through `ContentResolver`. Meta merges by group either way.
    /// - A thought not stored yet is created once both its records are here; with one, it is held back.
    /// - A deletion removes the thought (and leaves a tombstone), unless its content was edited after
    ///   `deletedAt`. Records for a thought with a tombstone bring it back only when newer than the deletion.
    /// - Nothing is enqueued for what was applied. Entities where the local side still differs from the
    ///   remote record come back in `requeue`, to be pushed against the remote seq.
    ///
    /// Saves in the steps `update` and `replace` use, so the `persist()` rollback rules hold; on a failure the
    /// batch may be partly applied and applying it again finishes the job. Not a view, an edit or an open: the
    /// rating and reminder prompts and the requeue-on-open logic are not involved.
    @discardableResult
    func applyRemote(_ batch: RemoteBatch, now: Date) -> RemoteOutcome {
        var outcome = RemoteOutcome()
        var work = RemoteWork()
        observeClocks(of: batch, now: now)
        applyRemoteSteps(batch, outcome: &outcome, work: &work)
        reindexAfterRemote(work, outcome: &outcome)
        return outcome
    }

    private struct RemoteWork {
        /// Every thought the batch decided something about, for the search index.
        var touched = Set<UUID>()
        /// The ones that are live afterwards, with the records to compare them with.
        var live: [UUID: RemoteThought] = [:]
    }

    private func applyRemoteSteps(_ batch: RemoteBatch, outcome: inout RemoteOutcome, work: inout RemoteWork) {
        let ids = batch.thoughts.map(\.id)
        let stored: [UUID: Thought]
        let tombstones: [UUID: Tombstone]
        do {
            stored = Dictionary(
                try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) })).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let kind = TombstoneKind.thought.rawValue
            tombstones = Dictionary(
                try context.fetch(FetchDescriptor<Tombstone>(predicate: #Predicate { ids.contains($0.id) && $0.kind == kind })).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            Self.logger.error("Remote apply lookup failed: \(error)")
            outcome.saved = false
            return
        }

        struct Candidate {
            var item: ImportedThought
            var local: Thought?
            var wins: GroupWins
        }
        var candidates: [Candidate] = []
        var deletions: [(thought: Thought, deletedAt: Date)] = []

        for remote in batch.thoughts {
            let id = remote.id
            if let deletion = remote.deletion, !(remote.content.map { $0.updatedAt > deletion.deletedAt } ?? false) {
                work.touched.insert(id)
                if let local = stored[id] {
                    if local.updatedAt > deletion.deletedAt {
                        outcome.requeue.insert(.thought(id))
                    } else {
                        deletions.append((local, deletion.deletedAt))
                    }
                }
                continue
            }
            guard let local = stored[id] else {
                guard let content = remote.content ?? remote.contentBase, let meta = remote.meta ?? remote.metaBase else {
                    outcome.held.insert(id)
                    continue
                }
                if let tombstone = tombstones[id], content.updatedAt <= tombstone.deletedAt {
                    outcome.requeue.insert(.thought(id))
                    continue
                }
                work.live[id] = remote
                work.touched.insert(id)
                let item = ImportedThought(record: ThoughtRecord(content: content, meta: meta), images: remote.images, files: remote.files)
                candidates.append(Candidate(item: item, local: nil, wins: GroupWins(content: true, schedule: true, state: true, counters: true)))
                continue
            }
            work.live[id] = remote
            work.touched.insert(id)
            let localContent = ThoughtContentRecord(local)
            let localMeta = ThoughtMetaRecord(local)
            var wins = GroupWins(content: false, schedule: false, state: false, counters: false)
            if let content = remote.content, content != localContent {
                let hasUnpushedChange = remote.contentBaseHash.map { SyncPayload.hash(of: Self.plaintext(localContent)) != $0 } ?? true
                if !hasUnpushedChange {
                    wins = GroupWins(content: true, schedule: false, state: false, counters: false)
                } else {
                    switch ContentResolver.resolve(base: remote.contentBase, local: localContent, remote: content) {
                    case .takeRemote: wins = GroupWins(content: true, schedule: false, state: false, counters: false)
                    case .keepLocal: outcome.requeue.insert(.thought(id))
                    }
                }
            }
            if let meta = remote.meta {
                let metaWins = RemoteMerge.metaWins(local: localMeta, remote: meta)
                wins = GroupWins(content: wins.content, schedule: metaWins.schedule, state: metaWins.state, counters: metaWins.counters)
            }
            guard wins.any else { continue }
            let record = ThoughtRecord(content: remote.content ?? localContent, meta: remote.meta ?? localMeta)
            candidates.append(Candidate(item: ImportedThought(record: record, images: remote.images, files: remote.files), local: local, wins: wins))
        }

        if !deletions.isEmpty {
            for (thought, deletedAt) in deletions {
                let id = thought.id
                deleteWithChildren(thought)
                context.insert(Tombstone(id: id, kind: .thought, deletedAt: deletedAt))
            }
            guard persist() else {
                outcome.saved = false
                return
            }
        }

        guard let lookup = lookUp(candidates.map(\.item)) else {
            outcome.saved = false
            return
        }
        var takenBlockIDs = lookup.takenBlockIDs
        var additions: [ImportedThought] = []
        var replacements: [Replacement] = []
        var claimedImageIDs = Set<UUID>()
        var claimedFileIDs = Set<UUID>()
        for candidate in candidates {
            let record = candidate.item.record
            if clashes(record, claimedImageIDs: claimedImageIDs, claimedFileIDs: claimedFileIDs, lookup: lookup) {
                Self.logger.error("Remote thought \(record.id) skipped: its images or files belong to another thought")
                outcome.rejected.insert(record.id)
                continue
            }
            if candidate.wins.content {
                claimedImageIDs.formUnion(record.imageIDs)
                claimedFileIDs.formUnion(record.fileIDs)
            }
            if let local = candidate.local {
                replacements.append(Replacement(thought: local, item: candidate.item, wins: candidate.wins))
            } else {
                additions.append(candidate.item)
            }
        }
        var tally = ImportTally()
        guard execute(additions: additions, replacements: replacements, tags: [], takenBlockIDs: &takenBlockIDs, tally: &tally) else {
            outcome.saved = false
            return
        }
        guard mergeRemoteTags(batch.tags, outcome: &outcome), mergeRemoteSettings(batch.settings, outcome: &outcome) else {
            outcome.saved = false
            return
        }
    }

    private static func plaintext(_ content: ThoughtContentRecord) -> Data {
        (try? SyncPayload.thoughtContent(content).encoded()) ?? Data()
    }

    /// Raises the skew-safe clock to the highest clock any record in the batch carries, applied or not, but never
    /// past a day after `now`: one device with a wild clock mustn't drag every later stamp into the future.
    /// The records themselves are applied with their real clocks.
    private func observeClocks(of batch: RemoteBatch, now: Date) {
        let clock = SyncClock(defaults: syncDefaults)
        let ceiling = now.addingTimeInterval(SyncClock.maxLead)
        func observe(_ seen: Date) { clock.observe(min(seen, ceiling)) }
        for remote in batch.thoughts {
            for seen in [remote.content?.updatedAt, remote.meta?.scheduleChangedAt, remote.meta?.stateChangedAt, remote.deletion?.deletedAt] {
                if let seen { observe(seen) }
            }
        }
        for tag in batch.tags { observe(tag.updatedClock) }
        if let settings = batch.settings { observe(settings.changedAt) }
    }

    /// Sends the index the thoughts as they now are, and compares each with the remote records it was given.
    private func reindexAfterRemote(_ work: RemoteWork, outcome: inout RemoteOutcome) {
        guard !work.touched.isEmpty else { return }
        let lookup = Array(work.touched)
        do {
            var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { lookup.contains($0.id) })
            descriptor.relationshipKeyPathsForPrefetching = [\.blocks, \.tags, \.files, \.images]
            let found = try context.fetch(descriptor)
            for thought in found {
                indexUpsert(thought)
                guard outcome.saved, let remote = work.live[thought.id] else { continue }
                if let content = remote.content, ThoughtContentRecord(thought) != content { outcome.requeue.insert(.thought(thought.id)) }
                if let meta = remote.meta, ThoughtMetaRecord(thought) != meta { outcome.requeue.insert(.thought(thought.id)) }
            }
            for id in work.touched.subtracting(found.map(\.id)) {
                searchIndex.submit(.remove(id))
            }
        } catch {
            Self.logger.error("Remote apply reindex fetch failed: \(error)")
        }
    }

    /// A tag's color and display name follow the later `updatedAt` (ties settled by value). A tag record for a
    /// tag this device doesn't have yet creates the tag, since its thoughts may arrive later; pruning removes
    /// it at launch if none does.
    private func mergeRemoteTags(_ records: [TagRecord], outcome: inout RemoteOutcome) -> Bool {
        let latest = Dictionary(
            records.filter { !$0.displayName.isEmpty && $0.name == $0.name.precomposedStringWithCanonicalMapping.lowercased() }
                .map { ($0.name, $0) },
            uniquingKeysWith: { first, second in RemoteMerge.tagWins(local: first, remote: second) ? second : first }
        )
        let names = Set(latest.keys)
        guard !names.isEmpty else { return true }
        var byName: [String: Tag]
        do {
            byName = Dictionary(
                try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { names.contains($0.name) })).map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            Self.logger.error("Remote tag lookup failed: \(error)")
            return false
        }
        for record in latest.values {
            if let tag = byName[record.name] {
                let local = TagRecord(name: tag.name, displayName: tag.displayName, colorHex: tag.colorHex, updatedAt: tag.updatedAt)
                if RemoteMerge.tagWins(local: local, remote: record) {
                    tag.displayName = record.displayName
                    tag.colorHex = record.colorHex.flatMap(TagColor.normalizedHex)
                    tag.updatedAt = record.updatedClock
                }
            } else {
                let tag = Tag(name: record.name, displayName: record.displayName, updatedAt: record.updatedClock)
                tag.colorHex = record.colorHex.flatMap(TagColor.normalizedHex)
                context.insert(tag)
                byName[record.name] = tag
            }
        }
        guard !context.hasChanges || persist() else { return false }
        for record in latest.values {
            guard let tag = byName[record.name] else { continue }
            if tag.displayName != record.displayName || tag.colorHex != record.colorHex || tag.updatedAt != record.updatedClock {
                outcome.requeue.insert(.tag(record.name))
            }
        }
        return true
    }

    private func mergeRemoteSettings(_ remote: SettingsRecord?, outcome: inout RemoteOutcome) -> Bool {
        guard let remote else { return true }
        let local = SettingsRecord.current(defaults: syncDefaults)
        guard local != remote else { return true }
        if RemoteMerge.settingsWin(local: local, remote: remote) {
            syncDefaults.set(remote.defaultIntervalDays, forKey: AppSettings.Key.defaultIntervalDays)
            syncDefaults.set(remote.changedAt, forKey: AppSettings.Key.defaultIntervalChangedAt)
        } else {
            outcome.requeue.insert(.settings)
        }
        return true
    }
}
