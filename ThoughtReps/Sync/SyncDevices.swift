#if DEBUG
import Foundation

enum SyncDevicePath {
    /// `vaults/{id}/devices/{keyId}`; in the path the keyId is unpadded base64url, not the standard base64 the body carries.
    static func device(vaultID: String, keyID: String) -> String {
        let component = keyID.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "vaults/\(vaultID)/devices/\(component)"
    }
}

/// The vault's devices as the Sync lab shows them: names opened on this device, never sent in the clear.
struct SyncDeviceList: Equatable {
    struct Device: Equatable, Identifiable {
        var keyId: String
        var name: String
        var addedAt: Date
        var lastSeenAt: Date
        var isCurrent: Bool

        var id: String { keyId }
    }

    static let unnamed = "Unnamed device"

    var devices: [Device]
    var deviceLimit: Int

    var countText: String {
        "\(devices.count) of \(deviceLimit) devices"
    }

    var current: Device? {
        devices.first(where: \.isCurrent)
    }

    /// A missing name, or one that doesn't open (sealed for another vault or device, or damaged), shows as "Unnamed device".
    init(_ list: SyncHTTPWireV1.DevicesList, vaultID: String, keys: SyncKeys) {
        deviceLimit = list.deviceLimit
        devices = list.devices.map { entry in
            let name = entry.nameSealed.flatMap { try? SyncCrypto.openDeviceName($0, vaultID: vaultID, keyID: entry.keyId, keys: keys) }
            return Device(
                keyId: entry.keyId, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unnamed,
                addedAt: Date(timeIntervalSince1970: Double(entry.addedAt) / 1000),
                lastSeenAt: Date(timeIntervalSince1970: Double(entry.lastSeenAt) / 1000), isCurrent: entry.current
            )
        }
    }
}

extension SyncAccountService {
    func listDevices(credentials held: SyncCredentials, session: SyncSessionSource) async throws -> SyncDeviceList {
        let list: SyncHTTPWireV1.DevicesList = try await withBearer(session) { token in
            try await api.bodyless("GET", "vaults/\(held.vaultID)/devices", bearer: token)
        }
        return SyncDeviceList(list, vaultID: held.vaultID, keys: try SyncKeys(vaultKey: held.vaultKey))
    }

    /// Only this device's own name can be set. An empty name clears it.
    func renameDevice(keyId: String, to name: String, credentials held: SyncCredentials, session: SyncSessionSource) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sealed = trimmed.isEmpty ? nil : try SyncCrypto.sealDeviceName(
            trimmed, vaultID: held.vaultID, keyID: keyId, keys: SyncKeys(vaultKey: held.vaultKey)
        )
        let body = try SyncAccountAPI.encode(SyncHTTPWireV1.DeviceNameRequest(nameSealed: sealed))
        let path = SyncDevicePath.device(vaultID: held.vaultID, keyID: keyId)
        let _: SyncHTTPWireV1.DeviceNameResponse = try await withBearer(session) { token in
            try await api.put(path, body: body, bearer: token)
        }
    }

    /// Any member can remove any member, itself included.
    func removeDevice(keyId: String, credentials held: SyncCredentials, session: SyncSessionSource) async throws {
        let path = SyncDevicePath.device(vaultID: held.vaultID, keyID: keyId)
        let _: SyncHTTPWireV1.DeviceRemoved = try await withBearer(session) { token in
            try await api.bodyless("DELETE", path, bearer: token)
        }
    }

    func leaveVault(credentials held: SyncCredentials, session: SyncSessionSource) async throws {
        guard let keyId = try api.storedKeyId() else { throw SyncAccountError.notRegistered }
        try await removeDevice(keyId: keyId, credentials: held, session: session)
    }

    /// `DELETE /account` from this device's session. If the server wants a recent Sign in with Apple, signs in once and
    /// retries once with that session, unless the Apple ID's account is not the vault this device holds.
    func deleteAccount(vaultID: String, session: SyncSessionSource) async throws {
        do {
            let _: SyncHTTPWireV1.AccountDeleted = try await withBearer(session) { token in
                try await api.bodyless("DELETE", "account", bearer: token)
            }
        } catch let error as SyncAccountError where error.wantsFreshSignIn {
            guard api.attest.isSupported else { throw SyncAccountError.unsupported }
            let account = try await signIn(keyId: try await api.registeredKeyId())
            guard account.vaultId == vaultID else { throw SyncAccountError.differentAccount }
            let _: SyncHTTPWireV1.AccountDeleted = try await api.bodyless("DELETE", "account", bearer: account.session.token)
        }
    }
}

extension SyncAccountError {
    var wantsFreshSignIn: Bool {
        code == .reauthenticationRequired
    }
}

/// The prompts of "Leave sync" and "Erase this device and leave sync", in order. Pure, like `JoinGate`: erasing always passes
/// a second, destructive confirmation, and a cancel at either prompt abandons everything.
enum LeaveGate {
    enum Step: Equatable {
        case confirmLeave(erase: Bool, thoughtCount: Int)
        case confirmErase(count: Int)
        /// Go ahead; `erase` runs `ThoughtStore.deleteAll` only after the server leave succeeded and sync is cleared.
        case run(erase: Bool)
        case cancelled
    }

    enum Action: Equatable {
        case confirm
        case cancel
    }

    static func begin(erase: Bool, thoughtCount: Int) -> Step {
        .confirmLeave(erase: erase, thoughtCount: thoughtCount)
    }

    static func advance(_ step: Step, _ action: Action) -> Step {
        switch (step, action) {
        case (.confirmLeave(let erase, let count), .confirm): erase ? (count > 0 ? .confirmErase(count: count) : .run(erase: true)) : .run(erase: false)
        case (.confirmErase, .confirm): .run(erase: true)
        case (.confirmLeave, .cancel), (.confirmErase, .cancel): .cancelled
        default: step
        }
    }

    static func leaveTitle(device: String) -> String {
        "Leave sync on this \(device)?"
    }

    static func leaveMessage(erase: Bool) -> String {
        erase
            ? "This device stops syncing, then you can erase its thoughts. The other devices keep theirs."
            : "This device stops syncing. Its thoughts stay on it, and the other devices keep theirs."
    }

    static func eraseTitle(count: Int, device: String) -> String {
        "Erase \(JoinGate.count(count)) from this \(device)?"
    }

    static let eraseMessage = "This can't be undone."

    static let deleteDataTitle = "Delete sync data?"
    static let deleteDataMessage = "Every device stops syncing and the synced copy is deleted from the server. Each device keeps its own thoughts."

    static func removeTitle(name: String) -> String {
        "Remove \(name)?"
    }

    static let removeMessage = "It stops syncing; its thoughts stay on it."
}

/// What the sync state file held when the app launched, to tell a launch of a reinstalled app from a launch of one that has
/// been syncing.
struct SyncProgress: Equatable {
    var vaultID: String?
    var cursor: Int64
    var epoch: Int64?
    var records: Int
    var outbox: Int

    /// No pull has ever landed (no cursor, no epoch, no record) and nothing is queued.
    var isEmpty: Bool {
        cursor == 0 && epoch == nil && records == 0 && outbox == 0
    }
}

enum SyncResumeGate {
    /// A key in the Keychain survives deleting the app; the sync state file doesn't. A key with no state for its vault means
    /// a reinstall, so the person is asked before the engine queues every thought. `progress` is nil when there is no state
    /// file.
    static func needsConfirmation(heldVaultID: String?, progress: SyncProgress?) -> Bool {
        guard let heldVaultID else { return false }
        guard let progress, progress.vaultID == heldVaultID else { return true }
        return progress.isEmpty
    }

    static let title = "Resume syncing with this vault?"
    static let message = "This device has the vault key but no sync history, as after a reinstall. Resuming queues every thought on this device to sync."
}
#endif
