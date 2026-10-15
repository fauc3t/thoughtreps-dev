import Foundation

/// One record in a push. `baseSeq` is the seq of the version this device last synced for the key; nil means
/// "there is no row yet". `payload` is sealed (`SyncCrypto.seal`).
struct PushRecord: Sendable, Equatable, Codable {
    var recordKey: String
    var baseSeq: Int64?
    var payload: Data
    var deleted: Bool
}

struct PulledRecord: Sendable, Equatable, Codable {
    var recordKey: String
    var seq: Int64
    var payload: Data
    var deleted: Bool
}

enum PushResult: Sendable, Equatable {
    /// Every record committed, with seqs assigned in the order pushed.
    case ok(seqs: [String: Int64], headSeq: Int64)
    /// Nothing committed: these keys' rows were not at `baseSeq`.
    case conflict(keys: [String])
}

struct PullPage: Sendable, Equatable {
    var records: [PulledRecord]
    /// How far the server had committed when the page was read: where the cursor goes once nothing is left (`hasMore` false).
    /// Equal to the last record's seq when `hasMore`. Everything at or below it is in this page or an earlier one.
    var nextSeq: Int64
    /// The server's head, for the poll only. It can be past `nextSeq` (a push landed after the page was read), so it is
    /// never a cursor.
    var headSeq: Int64
    var epoch: Int64
    var hasMore: Bool
}

enum PullResult: Sendable, Equatable {
    case page(PullPage)
    /// 410: the cursor is older than what the server still holds; do a full resync.
    case gone
}

struct SyncHead: Sendable, Equatable {
    var headSeq: Int64
    var epoch: Int64
    var liveRecordCount: Int
}

enum SyncTransportError: Error, Equatable {
    /// The call didn't reach the server or its answer was lost; the caller can't tell whether it committed.
    case unavailable
    case tooLarge
    case blobMissing(String)
    /// The vault's epoch is not the one the push carried: it was erased or replaced elsewhere. Nothing was written.
    case epochChanged(server: Int64)
}

/// What the sync engine needs from a server. Phase 2's HTTP client implements it; `FakeSyncServer` does in tests.
///
/// A push is all or nothing, at most `maxRecordsPerPush` records and `maxBytesPerPush` bytes of payload.
/// Per record the condition is "no row yet, or the row's seq equals `baseSeq`"; seqs are assigned
/// `headSeq + 1…` in order, so commit order matches seq order. A pull returns only the latest version of
/// each record, ascending by seq.
///
/// A push, a blob upload and a blob existence check carry the epoch the device last saw. The server checks it against
/// the vault's current epoch (for a push, in the same transactional write as the records) and, if it differs, writes
/// nothing and throws `epochChanged`, so a device that missed an erase cannot refill the vault.
///
/// A pull from before the pruned seq answers 410, because deletions older than that are gone and the client
/// may have missed them. `fullResync` says the client is pulling everything from scratch (a new device, or one
/// starting over after a 410), so it can't have missed anything and the cursor of its later pages must not 410.
///
/// A pull page's `nextSeq` is read in the same consistent snapshot as its records, so a push that lands afterwards
/// can't be skipped by moving the cursor to `nextSeq`. The client never moves its cursor to `headSeq`, and a page that
/// has more records must have a `nextSeq` past the cursor it was asked from.
///
/// `getBlob` must not read more than `maxBytes`: it throws `tooLarge` for a bigger blob, as soon as the size is known
/// (the `Content-Length`) or the download passes the limit.
protocol SyncTransport: Sendable {
    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult
    func pull(after cursor: Int64, limit: Int, fullResync: Bool) async throws -> PullResult
    func head() async throws -> SyncHead
    func putBlob(name: String, data: Data, epoch: Int64) async throws
    func getBlob(name: String, maxBytes: Int) async throws -> Data
    func hasBlob(name: String, epoch: Int64) async throws -> Bool
}

enum SyncLimits {
    static let maxRecordsPerPush = 99
    static let maxBytesPerPush = 2_000_000
    /// A record's payload goes inline up to this size; a bigger sealed record is uploaded as a blob and the row holds a pointer.
    static let maxInlinePayload = 64 * 1024
    /// The most a single sealed record may be, blob or not. A thought past it is held back (see `SyncEngine.Status.oversizedThoughts`).
    static let maxRecordBytes = 16 * 1_048_576
    /// Plaintext and blob bytes the engine plans in memory for one push chunk before sending it. One record bigger than
    /// this still goes alone.
    static let maxPlanBytes = 4_000_000
    /// Bytes held in memory while a pulled page is applied: resolved record payloads and decoded image and file bytes. A
    /// sub-batch is cut before it passes this, so a thought bigger than it goes alone.
    static let maxApplyBytes = 25_000_000
    /// The most one image or file blob download may be (`SyncTransport.getBlob(name:maxBytes:)`, plus the frame). Files may
    /// later grow to 25 to 50 MB; blobs should then stream through a temp file instead of memory (phase 3).
    static let maxAssetBlobBytes = 25_000_000
}
