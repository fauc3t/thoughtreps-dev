import Foundation

/// The sync server's JSON, frozen as v1. Pinned by the golden fixtures in `ThoughtRepsTests/Fixtures/SyncWireV1/`, which
/// mirror `thoughtreps-aws` `infra/lambda/sync/fixtures/wire-v1/`. Separate from the record structs and the backup's
/// types on purpose: a change to those must never change what goes over the wire. `payload` is standard base64, which
/// is `Data`'s default coding.
enum SyncHTTPWireV1 {
    struct PushRequest: Codable, Equatable {
        var epoch: Int64
        var records: [PushRecord]
    }

    struct PushRecord: Codable, Equatable {
        var key: String
        var baseSeq: Int64?
        var deleted: Bool
        var payload: Data

        enum CodingKeys: String, CodingKey { case key, baseSeq, deleted, payload }

        /// `baseSeq` is sent as an explicit null: the server's schema requires the field.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(baseSeq, forKey: .baseSeq)
            try container.encode(deleted, forKey: .deleted)
            try container.encode(payload, forKey: .payload)
        }
    }

    struct PushOK: Codable, Equatable {
        var headSeq: Int64
        var seqs: [String: Int64]
        var serverTime: Int64?
    }

    struct PulledRecord: Codable, Equatable {
        var key: String
        var seq: Int64
        var deleted: Bool
        var payload: Data
    }

    struct PullPage: Codable, Equatable {
        var records: [PulledRecord]
        var nextSeq: Int64
        var headSeq: Int64
        var more: Bool
        var epoch: Int64
        var serverTime: Int64?
    }

    struct Head: Codable, Equatable {
        var headSeq: Int64
        var epoch: Int64
        var liveRecordCount: Int
        var serverTime: Int64?
    }

    /// Every non-2xx body: `error` and `message` always, plus `conflicts` (409 conflict) or `epochChanged` and `epoch`
    /// (409 epoch_changed). A 500 from the gateway may carry none of them.
    struct ErrorBody: Codable, Equatable {
        var error: String?
        var message: String?
        var conflicts: [String]?
        var epochChanged: Bool?
        var epoch: Int64?
        var serverTime: Int64?
    }

    struct CreateVault: Codable, Equatable {
        var vaultId: String
        var epoch: Int64
        var created: Bool
        var serverTime: Int64?
    }

    struct CreateVaultRequest: Codable, Equatable {
        var vaultId: String?
    }

    struct EraseVault: Codable, Equatable {
        var epoch: Int64
        var serverTime: Int64?
    }

    /// Only the clock, for reading `serverTime` off any response.
    struct TimeOnly: Codable {
        var serverTime: Int64?
    }
}
