import Foundation

/// Why sync needs the person, one case per row of the Sync Setup Flow Spec's "Attention states" table. Copy and actions are
/// the view's; this is only which one applies.
enum SyncAttention: Equatable, Sendable {
    /// 402 `subscription_required`: paused with the outbox kept. `purgeAt` is when the server deletes the synced copy.
    case subscriptionLapsed(purgeAt: Date?)
    /// The vault's epoch changed after the subscription ended: the server deleted the synced copy.
    case syncedCopyPurged
    /// The vault's epoch changed because another device erased it.
    case resetFromAnotherDevice
    /// 413 `quota_exceeded`: this many thoughts wait for space; deletes and shrinks still sync.
    case storageFull(waitingThoughts: Int)
    case updateRequired
    /// The server answered 401 or 403: another device removed this one.
    case removedFromSync
    /// Any other refusal the engine stopped for.
    case syncStopped(status: Int)
}

/// What the Settings row shows.
enum SyncDisplayStatus: Equatable, Sendable {
    case off
    case syncing
    case upToDate
    /// Not running and not stopped for good: waiting for the person to resume after a reinstall, or for a connection after a
    /// failed cycle.
    case paused
    case needsAttention(SyncAttention)
}

/// Pure mapping from the engine's status (and what the controller remembers) to what the person sees.
enum SyncStatusMapping {
    struct Input: Equatable {
        var engine: SyncEngine.Status?
        /// A vault key is held but the engine waits for the person's Resume.
        var awaitingResume = false
        /// A subscription hold was seen during this run, so a later epoch change was the purge.
        var lapseSeen = false
        /// `GET /entitlement`'s status, if it was fetched after an epoch change.
        var entitlement: SyncHTTPWireV1.Entitlement.Status?
    }

    static func attention(_ input: Input) -> SyncAttention? {
        guard let status = input.engine else { return nil }
        switch status.attention {
        case .epochChanged?:
            let purged = input.lapseSeen || input.entitlement == .expired || input.entitlement == .revoked
            return purged ? .syncedCopyPurged : .resetFromAnotherDevice
        case .serverRefused(let code, _)?:
            return code == 401 || code == 403 ? .removedFromSync : .syncStopped(status: code)
        case nil:
            break
        }
        if let hold = status.subscriptionHold {
            return .subscriptionLapsed(purgeAt: hold.purgeAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
        if status.quotaExceededThoughts > 0 { return .storageFull(waitingThoughts: status.quotaExceededThoughts) }
        if status.updateRequired { return .updateRequired }
        return nil
    }

    /// The footer count: thoughts that can't sync until something outside the engine changes (too big, attachments missing,
    /// a blob missing or the server without blob storage). Thoughts waiting for a merge or for storage space have their own
    /// states.
    static func heldThoughts(_ status: SyncEngine.Status?) -> Int {
        guard let status else { return 0 }
        return status.oversizedThoughts + status.missingAttachments + status.waitingForBlobs + status.blockedThoughts
    }

    static func display(_ input: Input) -> SyncDisplayStatus {
        guard let status = input.engine else { return input.awaitingResume ? .paused : .off }
        if let attention = attention(input) { return .needsAttention(attention) }
        if status.phase == .pulling || status.phase == .pushing { return .syncing }
        if status.lastError != nil { return .paused }
        return status.cycles == 0 ? .syncing : .upToDate
    }
}
