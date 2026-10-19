#if DEBUG
import Foundation
import Testing
@testable import ThoughtReps

private final class MemoryCredentials: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncCredentials?
    init(_ value: SyncCredentials? = nil) { self.value = value }
    func load() throws -> SyncCredentials? { lock.withLock { value } }
    func save(_ credentials: SyncCredentials) throws { lock.withLock { value = credentials } }
    func clear() { lock.withLock { value = nil } }
}

private final class MemoryKeyIdStore: KeyIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() throws -> String? { lock.withLock { value } }
    func save(_ keyId: String) throws { lock.withLock { value = keyId } }
    func clear() { lock.withLock { value = nil } }
}

@Suite("Sync test reset")
struct SyncTestResetTests {
    private func held(_ vault: String) -> SyncCredentials {
        SyncCredentials(vaultKey: Data(repeating: 7, count: 32), vaultID: vault, userID: "user-1")
    }

    private func copy(_ store: SyncCredentialStore) -> ICloudKeyCopy {
        ICloudKeyCopy(store: store, defaults: UserDefaults(suiteName: "SyncTestResetTests.\(UUID().uuidString)")!)
    }

    @Test func onlyTestPrefixedVaultsAreTestVaults() {
        #expect(SyncTestReset.isTestVault("test-0a1b2c"))
        #expect(!SyncTestReset.isTestVault("itest0a1b2c"))
        #expect(!SyncTestReset.isTestVault("testing"))
        #expect(!SyncTestReset.isTestVault("5f1c0c0e-aaaa-bbbb-cccc-0123456789ab"))
    }

    @Test func theNonceFollowsTheLaunchArgument() {
        #expect(SyncTestReset.nonce(in: ["app", "-TRResetSyncTestState", "abc"]) == "abc")
        #expect(SyncTestReset.nonce(in: ["app", "-TRResetSyncTestState"]) == "")
        #expect(SyncTestReset.nonce(in: ["app", "-other", "abc"]) == nil)
    }

    @MainActor
    @Test func clearsTheLocalKeyAndTheKeyIdAndRemovesATestVaultsICloudCopy() async throws {
        let local = MemoryCredentials(held("test-1"))
        let keys = MemoryKeyIdStore("key-1")
        let cloud = MemoryCredentials(held("test-1"))
        let result = await SyncTestReset.run(
            nonce: "n1", state: SyncState(location: .inMemory), credentials: local, attestKeys: keys, iCloud: copy(cloud)
        )
        #expect(result == SyncTestReset.Result(nonce: "n1", hadKey: true, keyPresent: false, iCloudCopyRemoved: true, iCloudCopyKept: false))
        #expect(try local.load() == nil)
        #expect(try keys.load() == nil)
        #expect(try cloud.load() == nil)
    }

    @MainActor
    @Test func keepsAnICloudCopyThatIsNotATestVaults() async throws {
        let cloud = MemoryCredentials(held("5f1c0c0e-aaaa-bbbb-cccc-0123456789ab"))
        let result = await SyncTestReset.run(
            nonce: "n2", state: SyncState(location: .inMemory), credentials: MemoryCredentials(), attestKeys: MemoryKeyIdStore(),
            iCloud: copy(cloud)
        )
        #expect(result == SyncTestReset.Result(nonce: "n2", hadKey: false, keyPresent: false, iCloudCopyRemoved: false, iCloudCopyKept: true))
        #expect(try cloud.load() != nil)
    }
}
#endif
