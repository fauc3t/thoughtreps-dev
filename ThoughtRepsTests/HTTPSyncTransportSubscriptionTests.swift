import Foundation
import Testing
@testable import ThoughtReps

private final class SubscriptionFixtureToken {}

extension HTTPSyncTransportTests {
    private func fixture(_ name: String) throws -> String {
        let folder = try #require(Bundle(for: SubscriptionFixtureToken.self).url(forResource: "SyncWireV1", withExtension: nil))
        return String(decoding: try Data(contentsOf: folder.appendingPathComponent("\(name).json")), as: UTF8.self)
    }

    @Test func a402OnAnyCallIsASubscriptionRequiredCarryingThePurgeDate() async throws {
        let body = try fixture("error-subscription-required")
        let lapsed = transport { _ in .json(402, body) }
        let expected = SyncTransportError.subscriptionRequired(entitledUntil: 1_767_225_600_000, purgeAt: 1_769_817_600_000)
        await #expect(throws: expected) { try await lapsed.head() }
        await #expect(throws: expected) { try await lapsed.pull(after: 0, limit: 10) }
        await #expect(throws: expected) { try await lapsed.push([], epoch: 1) }
    }

    @Test func a402WithoutAReadableBodyIsStillASubscriptionRequired() async throws {
        let lapsed = transport { _ in .json(402, "not json") }
        await #expect(throws: SyncTransportError.subscriptionRequired(entitledUntil: nil, purgeAt: nil)) { try await lapsed.head() }
        #expect(requests.count == 1, "a 402 is not retried")
    }

    @Test func aPushQuotaExceededIsTheQuotaErrorAndATooLargeStaysTooLarge() async throws {
        let body = try fixture("push-quota-exceeded")
        let full = transport { _ in .json(413, body) }
        let record = PushRecord(recordKey: "a", baseSeq: nil, payload: Data(), deleted: false)
        await #expect(throws: SyncTransportError.quotaExceeded(usedBytes: 1_073_700_000, limitBytes: 1_073_741_824)) { try await full.push([record], epoch: 1) }
        let large = transport { _ in .json(413, #"{"error":"too_large","message":"Push is too large","serverTime":1}"#) }
        await #expect(throws: SyncTransportError.tooLarge) { try await large.push([record], epoch: 1) }
    }
}
