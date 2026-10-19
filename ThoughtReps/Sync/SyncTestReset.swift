#if DEBUG
import Foundation
import SwiftUI

/// DEBUG only: puts a device back to "never synced" for `scripts/sync-device-integ.sh`, with no network call. Runs at launch
/// when the launch arguments hold `-TRResetSyncTestState <nonce>` (before the engine could start from the Keychain), or from
/// the Sync lab's "Reset sync test state". The Keychain items survive an uninstall, so the script resets before it uninstalls.
enum SyncTestReset {
    static let launchArgument = "-TRResetSyncTestState"
    /// Relative to the app's container, so `devicectl device copy from` can pull it.
    static let resultPath = "Documents/sync-reset-result.json"

    struct Result: Codable, Equatable {
        var nonce: String
        var hadKey: Bool
        var keyPresent: Bool
        var iCloudCopyRemoved: Bool
        var iCloudCopyKept: Bool
    }

    /// Throwaway vaults made by the harness are named `test-...`; account vaults are UUIDs.
    static func isTestVault(_ id: String) -> Bool {
        id.hasPrefix("test-")
    }

    /// The text after the launch argument (empty if it is last), or nil when the argument isn't there.
    static func nonce(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
    }

    /// Forgets the local key, the sync App Attest key id and the sync state, and deletes the iCloud Keychain copy only when it
    /// belongs to a test vault, so a real copy of the tester's is left alone.
    @MainActor
    static func run(
        nonce: String, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        attestKeys: KeyIdStore = SyncAccountAPI.defaultKeyStore(), iCloud: ICloudKeyCopy = ICloudKeyCopy()
    ) async -> Result {
        let hadKey = ((try? credentials.load()) ?? nil) != nil
        await SyncDebugSession.forgetAccount(state: state, credentials: credentials, attestKeys: attestKeys)
        var removed = false
        var kept = false
        if let copy = (try? iCloud.load()) ?? nil {
            if isTestVault(copy.vaultID) {
                iCloud.delete()
                removed = true
            } else {
                kept = true
            }
        }
        let keyPresent = ((try? credentials.load()) ?? nil) != nil
        return Result(nonce: nonce, hadKey: hadKey, keyPresent: keyPresent, iCloudCopyRemoved: removed, iCloudCopyKept: kept)
    }

    static func writeResult(_ result: Result) {
        let file = URL(fileURLWithPath: resultPath, relativeTo: .homeDirectory)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result) { try? data.write(to: file, options: .atomic) }
    }
}

/// Latest engine status for the UI-test runner, which on a device can't read the app's status file. Only filled when
/// `THOUGHTREPS_SYNC_STATUS_PROBE` is set.
@MainActor
@Observable
final class SyncStatusProbe {
    static let shared = SyncStatusProbe()
    nonisolated static let isOn = !(ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_STATUS_PROBE"] ?? "").isEmpty
    var json = ""
}

/// A 1 pt invisible element whose accessibility value is the status JSON.
struct SyncStatusProbeView: View {
    var body: some View {
        if SyncStatusProbe.isOn {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("syncStatusProbe")
                .accessibilityValue(SyncStatusProbe.shared.json)
        }
    }
}
#endif
