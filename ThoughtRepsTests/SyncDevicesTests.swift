#if DEBUG
import Foundation
import SwiftData
import Testing
import os
@testable import ThoughtReps

private let vault = "k7P2mQx9LwT4vB8nRcZ1sA"
private let key = Data(0..<32)
private let ownKeyId = "AyBN6S4R/IxSgTm+QZBlkg64Pb/xpGY7vqRVqm6XAr0="
private let ownKeyPath = "AyBN6S4R_IxSgTm-QZBlkg64Pb_xpGY7vqRVqm6XAr0"
private let otherKeyId = "WIYFv1Ni6LfxcMiykmxAYasJp9lcdMb/m0UUC2eH4N4="
private let otherKeyPath = "WIYFv1Ni6LfxcMiykmxAYasJp9lcdMb_m0UUC2eH4N4"
private let apiURL = URL(string: "https://sync.test/api/v1")!

private func errorJSON(_ code: String) -> String { #"{"error":"\#(code)","message":"nope","serverTime":1768478400000}"# }

private final class RecordingHTTP: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler
    private let challenge = OSAllocatedUnfairLock(initialState: 0)

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func requests(method: String, suffix: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url!.path.hasSuffix(suffix) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body): (Int, String)
        if request.url!.path.hasSuffix("app-attest/challenge") {
            let n = challenge.withLock { $0 += 1; return $0 }
            (status, body) = (200, #"{"challenge":"challenge-\#(n)","expiresAt":1768478700000,"serverTime":1768478400000}"#)
        } else {
            (status, body) = handler(request)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct StubAttest: AttestService {
    let isSupported = true
    func generateKey() async throws -> String { "generated" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("assertion".utf8) }
}

private final class MemoryKeyId: KeyIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() throws -> String? { lock.withLock { value } }
    func save(_ keyId: String) throws { lock.withLock { value = keyId } }
    func clear() { lock.withLock { value = nil } }
}

private final class StubApple: AppleSignIn, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var signIns: Int { count.withLock { $0 } }
    func identityToken(nonce: String) async throws -> String {
        count.withLock { $0 += 1 }
        return "apple-token"
    }
}

private struct StubSession: SyncSessionSource {
    func token() async throws -> String { "member-token" }
    func refresh(after rejected: String) async throws -> String { "member-token-2" }
}

private struct Rig {
    var http: RecordingHTTP
    var credentials = ICloudKeyCopyTests.MemoryCredentials()
    var iCloudStore = ICloudKeyCopyTests.MemoryCredentials()
    var attestKeys = MemoryKeyId(ownKeyId)
    var apple = StubApple()
    var state = SyncState(location: .inMemory)
    let held = SyncCredentials(vaultKey: key, vaultID: vault, userID: "user-1")

    init(_ handler: @escaping RecordingHTTP.Handler) throws {
        http = RecordingHTTP(handler)
        try credentials.save(held)
        try iCloudStore.save(held)
    }

    var service: SyncAccountService {
        SyncAccountService(
            api: SyncAccountAPI(baseURL: apiURL, transport: http, attest: StubAttest(), keyStore: attestKeys), apple: apple,
            credentials: credentials,
            iCloud: ICloudKeyCopy(store: iCloudStore, defaults: UserDefaults(suiteName: "SyncDevicesTests.\(UUID().uuidString)")!)
        )
    }

    func configureState() async throws {
        try await state.configure(vaultID: vault)
        state.enqueue([.thought(UUID())])
        await state.flush()
    }

    var isCleared: Bool {
        get async {
            ((try? credentials.load()) ?? nil) == nil && ((try? attestKeys.load()) ?? nil) == nil && !state.isEnabled
        }
    }
}

private func bearer(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "Authorization") }

@Suite("Sync devices", .serialized)
@MainActor
struct SyncDevicesTests {
    static func sealed(_ name: String, keyId: String, vaultID: String = vault) throws -> String {
        try SyncCrypto.sealDeviceName(name, vaultID: vaultID, keyID: keyId, keys: SyncKeys(vaultKey: key)).base64EncodedString()
    }

    static func listJSON() throws -> String {
        let wrongAAD = try sealed("Stolen", keyId: "someone-else")
        return """
        {"devices":[
        {"keyId":"\(ownKeyId)","addedAt":1768392000000,"lastSeenAt":1768478400000,"nameSealed":"\(try sealed("Nick's iPhone", keyId: ownKeyId))","current":true},
        {"keyId":"\(otherKeyId)","addedAt":1768474800000,"lastSeenAt":1768478340000,"nameSealed":null,"current":false},
        {"keyId":"third","addedAt":1768474800000,"lastSeenAt":1768478340000,"nameSealed":"\(wrongAAD)","current":false},
        {"keyId":"fourth","addedAt":1,"lastSeenAt":2,"nameSealed":"AAAA","current":false}
        ],"deviceLimit":5,"serverTime":1768478400000}
        """
    }

    // MARK: List and names

    @Test func theListOpensNamesAndFallsBackToUnnamed() async throws {
        let json = try Self.listJSON()
        let rig = try Rig { _ in (200, json) }
        let list = try await rig.service.listDevices(credentials: rig.held, session: StubSession())
        #expect(list.devices.map(\.name) == ["Nick's iPhone", "Unnamed device", "Unnamed device", "Unnamed device"])
        #expect(list.devices.map(\.isCurrent) == [true, false, false, false])
        #expect(list.current?.keyId == ownKeyId)
        #expect(list.countText == "4 of 5 devices")
        #expect(list.devices[0].addedAt == Date(timeIntervalSince1970: 1_768_392_000))
        #expect(list.devices[0].lastSeenAt == Date(timeIntervalSince1970: 1_768_478_400))
        let request = try #require(rig.http.requests.first)
        #expect(request.httpMethod == "GET" && request.url!.path == "/api/v1/vaults/\(vault)/devices")
        #expect(bearer(request) == "Bearer member-token")
    }

    @Test func theGoldenFixtureDecodesToUnnamedDevices() throws {
        let folder = try #require(Bundle(for: DevicesBundleToken.self).url(forResource: "SyncWireV1", withExtension: nil))
        let data = try Data(contentsOf: folder.appending(path: "devices-list-response.json"))
        let wire = try JSONDecoder().decode(SyncHTTPWireV1.DevicesList.self, from: data)
        let list = SyncDeviceList(wire, vaultID: vault, keys: try SyncKeys(vaultKey: key))
        #expect(list.devices.count == 2 && list.deviceLimit == 3)
        #expect(list.devices.allSatisfy { $0.name == "Unnamed device" })
    }

    // MARK: Rename and remove

    @Test func renamingPutsThisDevicesSealedNameToTheBase64URLPath() async throws {
        let rig = try Rig { _ in (200, #"{"nameSealed":null,"serverTime":1}"#) }
        try await rig.service.renameDevice(keyId: ownKeyId, to: "  Desk iPad ", credentials: rig.held, session: StubSession())
        let put = try #require(rig.http.requests.first)
        #expect(put.httpMethod == "PUT" && put.url!.path == "/api/v1/vaults/\(vault)/devices/\(ownKeyPath)")
        #expect(bearer(put) == "Bearer member-token")
        let body = try JSONDecoder().decode(SyncHTTPWireV1.DeviceNameRequest.self, from: try #require(put.httpBody))
        #expect(try SyncCrypto.openDeviceName(try #require(body.nameSealed), vaultID: vault, keyID: ownKeyId, keys: SyncKeys(vaultKey: key)) == "Desk iPad")
    }

    @Test func anEmptyNameClearsIt() async throws {
        let rig = try Rig { _ in (200, #"{"nameSealed":null,"serverTime":1}"#) }
        try await rig.service.renameDevice(keyId: ownKeyId, to: "   ", credentials: rig.held, session: StubSession())
        let body = try #require(rig.http.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(#""nameSealed":null"#))
    }

    @Test func removingDeletesTheOtherDevicesPath() async throws {
        let rig = try Rig { _ in (200, #"{"removed":true,"serverTime":1}"#) }
        try await rig.service.removeDevice(keyId: otherKeyId, credentials: rig.held, session: StubSession())
        let delete = try #require(rig.http.requests.first)
        #expect(delete.httpMethod == "DELETE" && delete.url!.path == "/api/v1/vaults/\(vault)/devices/\(otherKeyPath)")
        #expect(delete.httpBody == nil && bearer(delete) == "Bearer member-token")
    }

    @Test func aRefusedRemovalSurfaces() async throws {
        let rig = try Rig { _ in (403, errorJSON("forbidden")) }
        await #expect(throws: SyncAccountError.server(status: 403, code: "forbidden")) {
            try await rig.service.removeDevice(keyId: otherKeyId, credentials: rig.held, session: StubSession())
        }
    }

    // MARK: Leaving

    @Test func leavingDeletesOwnDeviceThenClearsEverythingButTheICloudCopy() async throws {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        var rig = try Rig { _ in (200, #"{"removed":true,"serverTime":1}"#) }
        try await rig.configureState()
        let credentials = rig.credentials
        let attestKeys = rig.attestKeys
        rig.http = RecordingHTTP { request in
            log.withLock { $0.append("DELETE, key held: \(((try? credentials.load()) ?? nil) != nil), attest key: \(((try? attestKeys.load()) ?? nil) != nil)") }
            return (200, #"{"removed":true,"serverTime":1}"#)
        }
        let result = await SyncDebugSession.leaveSync(service: rig.service, state: rig.state, session: StubSession())
        #expect(result == .left)
        #expect(log.withLock { $0 } == ["DELETE, key held: true, attest key: true"])
        let delete = try #require(rig.http.requests.first)
        #expect(delete.httpMethod == "DELETE" && delete.url!.path == "/api/v1/vaults/\(vault)/devices/\(ownKeyPath)")
        #expect(await rig.isCleared)
        #expect(try rig.iCloudStore.load() == rig.held, "the iCloud copy is kept")
    }

    @Test func aFailedLeaveClearsAndErasesNothing() async throws {
        for failure in [(500, "{}"), (403, errorJSON("forbidden")), (401, errorJSON("unauthorized"))] {
            let rig = try Rig { _ in failure }
            try await rig.configureState()
            let erased = OSAllocatedUnfairLock(initialState: false)
            let result = await SyncDebugSession.leaveSync(
                erase: { erased.withLock { $0 = true }; return true }, service: rig.service, state: rig.state, session: StubSession()
            )
            guard case .failed = result else { Issue.record("\(failure.0): \(result)"); continue }
            #expect(erased.withLock { $0 } == false)
            #expect(try rig.credentials.load() == rig.held)
            #expect(try rig.attestKeys.load() == ownKeyId)
            #expect(rig.state.isEnabled)
            let queued = try await rig.state.outboxCount()
            #expect(queued == 1)
        }
    }

    @Test func aRemovedDeviceCannotLeaveAndClearsNothing() async throws {
        for status in [401, 403] {
            let rig = try Rig { _ in (status, errorJSON("forbidden")) }
            try await rig.configureState()
            let result = await SyncDebugSession.leaveSync(erase: { true }, service: rig.service, state: rig.state, session: StubSession())
            #expect(result == .failed("This device was removed from sync or can't reach its account. Use Sign out and forget key."))
            #expect(try rig.credentials.load() == rig.held && rig.state.isEnabled)
        }
    }

    @Test func aLeaveWithoutAKeyOnTheDeviceFailsWithoutACall() async throws {
        let rig = try Rig { _ in (200, "{}") }
        rig.credentials.clear()
        let result = await SyncDebugSession.leaveSync(service: rig.service, state: rig.state, session: StubSession())
        #expect(result == .failed("No key on this device.") && rig.http.requests.isEmpty)
    }

    @Test func theEraseRunsAfterTheServerLeaveAndTheClear() async throws {
        let rig = try Rig { _ in (200, #"{"removed":true,"serverTime":1}"#) }
        try await rig.configureState()
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let result = await SyncDebugSession.leaveSync(
            erase: {
                let cleared = ((try? rig.credentials.load()) ?? nil) == nil && ((try? rig.attestKeys.load()) ?? nil) == nil
                seen.withLock { $0 = ["deletes sent: \(rig.http.requests.count)", "cleared: \(cleared)", "state on: \(rig.state.isEnabled)"] }
                return true
            },
            service: rig.service, state: rig.state, session: StubSession()
        )
        #expect(result == .leftAndErased)
        #expect(seen.withLock { $0 } == ["deletes sent: 1", "cleared: true", "state on: false"])
    }

    @Test func aFailedEraseAfterALeaveIsReported() async throws {
        let rig = try Rig { _ in (200, #"{"removed":true,"serverTime":1}"#) }
        let result = await SyncDebugSession.leaveSync(erase: { false }, service: rig.service, state: rig.state, session: StubSession())
        #expect(result == .eraseFailed)
        #expect(await rig.isCleared)
    }

    @Test func eraseWritesAfterTheClearAreNeverEnqueued() async throws {
        let rig = try Rig { _ in (200, #"{"removed":true,"serverTime":1}"#) }
        try await rig.configureState()
        _ = await SyncDebugSession.leaveSync(
            erase: { rig.state.enqueue([.thought(UUID())]); return true }, service: rig.service, state: rig.state, session: StubSession()
        )
        #expect(!rig.state.isEnabled)
        let queued = try? await rig.state.outboxCount()
        #expect(queued == nil || queued == 0)
    }

    // MARK: Delete sync data

    @Test func deletingSyncDataClearsTheDeviceAndTheICloudCopy() async throws {
        let rig = try Rig { _ in (200, #"{"deleted":true,"serverTime":1}"#) }
        try await rig.configureState()
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure == nil)
        let delete = try #require(rig.http.requests.first)
        #expect(delete.httpMethod == "DELETE" && delete.url!.path == "/api/v1/account" && bearer(delete) == "Bearer member-token")
        #expect(rig.http.requests.count == 1 && rig.apple.signIns == 0)
        #expect(await rig.isCleared)
        #expect(try rig.iCloudStore.load() == nil)
    }

    @Test func aReauthenticationRequestSignsInWithAppleAndRetriesOnce() async throws {
        let deletes = OSAllocatedUnfairLock(initialState: 0)
        let rig = try Rig { request in
            if request.url!.path.hasSuffix("sign-in-with-apple") {
                return (200, #"{"userId":"user-1","vaultId":"\#(vault)","session":{"token":"fresh-token","expiresAt":1768482000000},"serverTime":1}"#)
            }
            let n = deletes.withLock { $0 += 1; return $0 }
            return n == 1 ? (403, errorJSON("reauthentication_required")) : (200, #"{"deleted":true,"serverTime":1}"#)
        }
        try await rig.configureState()
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure == nil)
        let sent = rig.http.requests(method: "DELETE", suffix: "/account")
        #expect(sent.map(bearer) == ["Bearer member-token", "Bearer fresh-token"])
        #expect(rig.apple.signIns == 1)
        #expect(await rig.isCleared)
        #expect(try rig.iCloudStore.load() == nil)
    }

    @Test func aSecondReauthenticationRefusalGivesUpAndClearsNothing() async throws {
        let rig = try Rig { request in
            if request.url!.path.hasSuffix("sign-in-with-apple") {
                return (200, #"{"userId":"user-1","vaultId":"\#(vault)","session":{"token":"fresh-token","expiresAt":1768482000000},"serverTime":1}"#)
            }
            return (403, errorJSON("reauthentication_required"))
        }
        try await rig.configureState()
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure != nil)
        #expect(rig.http.requests(method: "DELETE", suffix: "/account").count == 2)
        #expect(rig.apple.signIns == 1)
        #expect(try rig.credentials.load() == rig.held && rig.state.isEnabled)
        #expect(try rig.iCloudStore.load() == rig.held)
    }

    @Test func aDifferentAppleAccountDeletesNothing() async throws {
        let rig = try Rig { request in
            if request.url!.path.hasSuffix("sign-in-with-apple") {
                return (200, #"{"userId":"user-2","vaultId":"someone-elses-vault","session":{"token":"fresh-token","expiresAt":1768482000000},"serverTime":1}"#)
            }
            return (403, errorJSON("reauthentication_required"))
        }
        try await rig.configureState()
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure == "That Apple ID's sync account isn't the one this device is in. Nothing was deleted.")
        #expect(rig.http.requests(method: "DELETE", suffix: "/account").count == 1)
        #expect(try rig.credentials.load() == rig.held && rig.state.isEnabled)
        #expect(try rig.iCloudStore.load() == rig.held)
    }

    @Test func aPlain403DoesNotSignInWithApple() async throws {
        let rig = try Rig { _ in (403, errorJSON("forbidden")) }
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure != nil && rig.apple.signIns == 0)
    }

    @Test func aServerErrorDeletesAndClearsNothing() async throws {
        let rig = try Rig { _ in (500, "{}") }
        let failure = await SyncDebugSession.deleteSyncData(service: rig.service, state: rig.state, session: StubSession())
        #expect(failure != nil && rig.apple.signIns == 0)
        #expect(try rig.credentials.load() == rig.held)
        #expect(try rig.iCloudStore.load() == rig.held)
        #expect(try rig.attestKeys.load() == ownKeyId)
    }

    // MARK: Gates

    @Test func leavingAsksOnceAndErasingAsksAgain() {
        let begin = LeaveGate.begin(erase: false, thoughtCount: 5)
        #expect(LeaveGate.advance(begin, .confirm) == .run(erase: false))
        #expect(LeaveGate.advance(begin, .cancel) == .cancelled)
        let erase = LeaveGate.begin(erase: true, thoughtCount: 5)
        let second = LeaveGate.advance(erase, .confirm)
        #expect(second == .confirmErase(count: 5))
        #expect(LeaveGate.advance(second, .confirm) == .run(erase: true))
        #expect(LeaveGate.advance(second, .cancel) == .cancelled)
        #expect(LeaveGate.advance(erase, .cancel) == .cancelled)
    }

    @Test func erasingWithNoThoughtsSkipsTheSecondConfirmButStillErases() {
        #expect(LeaveGate.advance(LeaveGate.begin(erase: true, thoughtCount: 0), .confirm) == .run(erase: true))
    }

    @Test func aFinishedStepStaysFinished() {
        #expect(LeaveGate.advance(.run(erase: true), .cancel) == .run(erase: true))
        #expect(LeaveGate.advance(.cancelled, .confirm) == .cancelled)
    }

    @Test func theTextNamesTheDeviceAndTheCount() {
        #expect(LeaveGate.eraseTitle(count: 1, device: "iPad") == "Erase 1 thought from this iPad?")
        #expect(LeaveGate.eraseTitle(count: 12, device: "iPhone") == "Erase 12 thoughts from this iPhone?")
        #expect(LeaveGate.removeTitle(name: "Desk iPad") == "Remove Desk iPad?")
        #expect(LeaveGate.removeMessage == "It stops syncing; its thoughts stay on it.")
    }

    // MARK: Reinstall check

    @Test func aKeyWithNoStateMeansAReinstall() {
        #expect(SyncResumeGate.needsConfirmation(heldVaultID: vault, progress: nil))
        #expect(SyncResumeGate.needsConfirmation(heldVaultID: vault, progress: SyncProgress(vaultID: vault, cursor: 0, epoch: nil, records: 0, outbox: 0)))
        #expect(SyncResumeGate.needsConfirmation(heldVaultID: vault, progress: SyncProgress(vaultID: "other", cursor: 9, epoch: 1, records: 3, outbox: 2)))
    }

    @Test func anyCursorEpochRecordOrEntryIsSyncHistory() {
        for progress in [
            SyncProgress(vaultID: vault, cursor: 1, epoch: nil, records: 0, outbox: 0),
            SyncProgress(vaultID: vault, cursor: 0, epoch: 1, records: 0, outbox: 0),
            SyncProgress(vaultID: vault, cursor: 0, epoch: nil, records: 1, outbox: 0),
            SyncProgress(vaultID: vault, cursor: 0, epoch: nil, records: 0, outbox: 1),
        ] {
            #expect(!SyncResumeGate.needsConfirmation(heldVaultID: vault, progress: progress))
        }
    }

    @Test func noKeyNeverAsks() {
        #expect(!SyncResumeGate.needsConfirmation(heldVaultID: nil, progress: nil))
    }

    @Test func progressReadsTheStateFile() async throws {
        let state = SyncState(location: .inMemory)
        #expect(await SyncDebugSession.progress(of: state) == nil)
        try await state.configure(vaultID: vault)
        #expect(await SyncDebugSession.progress(of: state) == SyncProgress(vaultID: vault, cursor: 0, epoch: nil, records: 0, outbox: 0))
        try await state.setCursor(7)
        try await state.setEpoch(2)
        #expect(await SyncDebugSession.progress(of: state) == SyncProgress(vaultID: vault, cursor: 7, epoch: 2, records: 0, outbox: 0))
    }

    @Test func resumeStartsTheEngineOnceAndEndsTheWait() async throws {
        let rig = try Rig { _ in (200, "{}") }
        let container = try ModelContainer.thoughtReps(inMemory: true)
        await SyncDebugSession.launch(container: container, state: rig.state, credentials: rig.credentials)
        #expect(SyncDebugSession.awaitingResume)
        let starts = OSAllocatedUnfairLock(initialState: 0)
        await SyncDebugSession.resume(container: container, state: rig.state, credentials: rig.credentials, start: { starts.withLock { $0 += 1 } })
        await SyncDebugSession.resume(container: container, state: rig.state, credentials: rig.credentials, start: { starts.withLock { $0 += 1 } })
        #expect(!SyncDebugSession.awaitingResume)
        #expect(starts.withLock { $0 } == 1)
    }

    @Test func launchWaitsForAKeyWithoutStateAndForgetEndsTheWait() async throws {
        let rig = try Rig { _ in (200, "{}") }
        let container = try ModelContainer.thoughtReps(inMemory: true)
        await SyncDebugSession.launch(container: container, state: rig.state, credentials: rig.credentials)
        #expect(SyncDebugSession.awaitingResume)
        #expect(!rig.state.isEnabled, "the outbox stays off until the person resumes")
        await SyncDebugSession.forgetAccount(state: rig.state, credentials: rig.credentials, attestKeys: rig.attestKeys)
        #expect(!SyncDebugSession.awaitingResume)
        #expect(await rig.isCleared)
    }
}
private final class DevicesBundleToken {}
#endif
