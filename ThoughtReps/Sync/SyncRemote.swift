import Foundation

/// What one pulled page says about one thought. `content` and `meta` are the newest versions available:
/// the page's, or a record held back from an earlier page.
struct RemoteThought: Sendable {
    var id: UUID
    var content: ThoughtContentRecord?
    var meta: ThoughtMetaRecord?
    var deletion: SyncDeletion?
    /// The content record last synced for the thought, and the hash of its plaintext; nil if there is none
    /// (or it was a deletion). A local content that differs from it has not been pushed yet.
    var contentBase: ThoughtContentRecord?
    var contentBaseHash: String?
    /// The meta record last synced, used (like `contentBase`) only to create a thought whose other record
    /// hasn't changed since.
    var metaBase: ThoughtMetaRecord?
    /// Blobs downloaded for the images and files `content` references that the store doesn't have.
    var images: [UUID: ProcessedImage] = [:]
    var files: [UUID: FileDraft] = [:]
}

struct RemoteBatch: Sendable {
    var thoughts: [RemoteThought] = []
    var tags: [TagRecord] = []
    var settings: SettingsRecord?
}

struct RemoteOutcome: Sendable, Equatable {
    /// False if a save or fetch failed; the batch may be partly applied, and applying it again finishes it.
    var saved = true
    /// Entities where the local side kept something the remote one lacks; they must be pushed.
    var requeue: Set<SyncEntity> = []
    /// Thoughts that couldn't be created because only one of their two records is here yet.
    var held: Set<UUID> = []
    /// Thoughts left out because their images or files belong to another thought.
    var rejected: Set<UUID> = []

    mutating func merge(_ other: RemoteOutcome) {
        saved = saved && other.saved
        requeue.formUnion(other.requeue)
        held.formUnion(other.held)
        rejected.formUnion(other.rejected)
    }
}

/// Decides a collision: a pulled `thought.content` landing on a thought whose content has a change not yet
/// pushed. This is the one place the 3-way merge and conflict copies plug in (`base` is the content last synced).
enum ContentResolver {
    enum Resolution: Equatable {
        case takeRemote
        case keepLocal
    }

    /// For now the later `updatedAt` wins whole, and an equal one is settled by comparing the records'
    /// hashes so that every device picks the same side.
    static func resolve(base: ThoughtContentRecord?, local: ThoughtContentRecord, remote: ThoughtContentRecord) -> Resolution {
        if remote.updatedAt != local.updatedAt { return remote.updatedAt > local.updatedAt ? .takeRemote : .keepLocal }
        return hash(remote) >= hash(local) ? .takeRemote : .keepLocal
    }

    private static func hash(_ record: ThoughtContentRecord) -> String {
        SyncPayload.hash(of: (try? SyncPayload.thoughtContent(record).encoded()) ?? Data())
    }
}

extension ThoughtRecord {
    /// A backup-style record from a thought's two sync records, so the import merge can apply it.
    init(content: ThoughtContentRecord, meta: ThoughtMetaRecord) {
        self.init(
            id: content.id, body: content.body, createdAt: content.createdAt, updatedAt: content.updatedAt,
            scheduleChangedAt: meta.scheduleChangedAt, stateChangedAt: meta.stateChangedAt,
            nextDueAt: meta.nextDueAt, lastViewedAt: meta.lastViewedAt, viewCount: meta.viewCount,
            intervalDays: meta.intervalDays, intervalModeRaw: meta.intervalModeRaw, learnIntervalDays: meta.learnIntervalDays,
            isPinned: meta.isPinned, isArchived: meta.isArchived, archivedAt: meta.archivedAt, conflictOfID: meta.conflictOfID,
            tags: [], blocks: content.blocks, images: content.images
        )
    }
}

enum RemoteMerge {
    /// Which meta groups the remote record takes from the local one. Each group wins on its own clock; an
    /// equal clock with different values is settled by comparing the values, so every device picks the same
    /// side. Counters merge by max on no clock.
    static func metaWins(local: ThoughtMetaRecord, remote: ThoughtMetaRecord) -> ThoughtStore.GroupWins {
        func wins(_ remoteClock: Date, _ localClock: Date, _ remoteKey: String, _ localKey: String) -> Bool {
            remoteClock != localClock ? remoteClock > localClock : remoteKey > localKey
        }
        return ThoughtStore.GroupWins(
            content: false,
            schedule: wins(remote.scheduleChangedAt, local.scheduleChangedAt, scheduleKey(remote), scheduleKey(local)),
            state: wins(remote.stateChangedAt, local.stateChangedAt, stateKey(remote), stateKey(local)),
            counters: remote.viewCount > local.viewCount || (remote.lastViewedAt ?? .distantPast) > (local.lastViewedAt ?? .distantPast)
        )
    }

    /// Whether a remote tag record replaces the local tag: the later `updatedAt`, ties settled by value.
    static func tagWins(local: TagRecord, remote: TagRecord) -> Bool {
        func key(_ tag: TagRecord) -> String { "\(tag.colorHex ?? "")|\(tag.displayName)" }
        return remote.updatedClock != local.updatedClock ? remote.updatedClock > local.updatedClock : key(remote) > key(local)
    }

    static func settingsWin(local: SettingsRecord, remote: SettingsRecord) -> Bool {
        remote.changedAt != local.changedAt ? remote.changedAt > local.changedAt : remote.defaultIntervalDays > local.defaultIntervalDays
    }

    private static func scheduleKey(_ meta: ThoughtMetaRecord) -> String {
        "\(SyncFingerprint.exact(meta.nextDueAt))|\(meta.intervalDays ?? -1)|\(meta.intervalModeRaw)|\(meta.learnIntervalDays ?? -1)"
    }

    private static func stateKey(_ meta: ThoughtMetaRecord) -> String {
        "\(meta.isPinned)|\(meta.isArchived)|\(meta.archivedAt.map(SyncFingerprint.exact) ?? "-")|\(meta.conflictOfID?.uuidString ?? "-")"
    }
}
