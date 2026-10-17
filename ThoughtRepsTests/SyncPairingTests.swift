import CryptoKit
import Foundation
import Testing
@testable import ThoughtReps

private let vaultID = "k7P2mQx9LwT4vB8nRcZ1sA"
private let vaultKey = Data(0..<32)
private let keyID = "AyBN6S4R/IxSgTm+QZBlkg64Pb/xpGY7vqRVqm6XAr0="

/// Both vectors below were computed outside this code base (Node's crypto), from the formats in `designs/`.
@Suite("Sync recovery code")
struct SyncRecoveryCodeTests {
    static let golden = "JESZ-D68C-FMQG-9Y5W-3WKM-BHKN-P000-20G3-0G2G-C1R8-1450-P30D-1R7H-048J-2CA1-A5GQ-30CH-M6RW-3MF1-Y716"

    @Test func encodesTheGoldenVector() throws {
        #expect(try SyncRecoveryCode.encode(vaultID: vaultID, vaultKey: vaultKey) == Self.golden)
    }

    @Test func parsesTheGoldenVector() throws {
        #expect(try SyncRecoveryCode.parse(Self.golden) == SyncRecoveryCode.Parsed(vaultID: vaultID, vaultKey: vaultKey))
    }

    @Test func isTwentyGroupsOfFourCrockfordCharacters() throws {
        let code = try SyncRecoveryCode.encode(vaultID: vaultID, vaultKey: Data(repeating: 0xFF, count: 32))
        let groups = code.split(separator: "-")
        #expect(groups.count == 20 && groups.allSatisfy { $0.count == 4 })
        #expect(code.allSatisfy { $0 == "-" || SyncRecoveryCode.alphabet.contains($0) })
    }

    @Test func randomKeysRoundTrip() throws {
        for _ in 0..<50 {
            let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let id = SyncCrypto.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            let parsed = try SyncRecoveryCode.parse(SyncRecoveryCode.encode(vaultID: id, vaultKey: key))
            #expect(parsed == SyncRecoveryCode.Parsed(vaultID: id, vaultKey: key))
        }
    }

    @Test func ignoresCaseSpacesHyphensAndLineBreaks() throws {
        let sloppy = Self.golden.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(try SyncRecoveryCode.parse("  " + sloppy + "\n").vaultKey == vaultKey)
        #expect(try SyncRecoveryCode.parse(Self.golden.replacingOccurrences(of: "-", with: "")).vaultKey == vaultKey)
        #expect(try SyncRecoveryCode.parse(Self.golden.replacingOccurrences(of: "-Z", with: "-Z\n")).vaultKey == vaultKey)
    }

    @Test func readsIAndLAsOneAndOAsZero() throws {
        // The golden code has 1s and 0s in "P000", "1450", "C1R8" and "3MF1".
        let typed = Self.golden.replacingOccurrences(of: "P000", with: "PoOO").replacingOccurrences(of: "1450", with: "I45O")
            .replacingOccurrences(of: "C1R8", with: "CLR8").replacingOccurrences(of: "3MF1", with: "3MFl")
        #expect(typed != Self.golden)
        #expect(try SyncRecoveryCode.parse(typed).vaultKey == vaultKey)
    }

    @Test func refusesTheWrongLengthBeforeAnythingElse() {
        for text in ["", "ABCD", String(Self.golden.dropLast()), Self.golden + "0"] {
            #expect(throws: SyncRecoveryCode.Failure.wrongLength, "\(text.count)") { try SyncRecoveryCode.parse(text) }
        }
    }

    @Test func refusesCharactersOutsideTheAlphabet() {
        for bad in ["U", "u", "!", "é", "ß"] {
            let text = String(Self.golden.dropLast()) + bad
            #expect(throws: SyncRecoveryCode.Failure.invalidCharacter, "\(bad)") { try SyncRecoveryCode.parse(text) }
        }
    }

    @Test func aSingleWrongCharacterFailsTheChecksum() throws {
        let characters = Array(Self.golden.replacingOccurrences(of: "-", with: ""))
        for index in [0, 1, 20, 41, 78, 79] {
            var changed = characters
            let position = SyncRecoveryCode.alphabet.firstIndex(of: changed[index])!
            changed[index] = SyncRecoveryCode.alphabet[(position + 1) % 32]
            #expect(throws: SyncRecoveryCode.Failure.badChecksum, "\(index)") { try SyncRecoveryCode.parse(String(changed)) }
        }
    }

    @Test func refusesWhatIsNotAVaultToEncode() {
        #expect(throws: SyncRecoveryCode.Failure.notAVault) { try SyncRecoveryCode.encode(vaultID: "short", vaultKey: vaultKey) }
        #expect(throws: SyncRecoveryCode.Failure.notAVault) { try SyncRecoveryCode.encode(vaultID: vaultID, vaultKey: Data(0..<31)) }
        // 22 characters that decode to 16 bytes plus leftover bits are not the canonical id.
        #expect(throws: SyncRecoveryCode.Failure.notAVault) { try SyncRecoveryCode.encode(vaultID: "k7P2mQx9LwT4vB8nRcZ1sB", vaultKey: vaultKey) }
    }

    @Test func everyFailureHasAPlainMessage() {
        for failure in [SyncRecoveryCode.Failure.wrongLength, .invalidCharacter, .badChecksum, .notAVault] {
            #expect(!failure.message.isEmpty)
        }
    }
}

@Suite("Sync pairing QR payload")
struct SyncPairingInviteTests {
    static let secret = Data(0x10...0x2F)
    static let golden = "thoughtreps-pair:v1:k7P2mQx9LwT4vB8nRcZ1sA:EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    @Test func buildsTheGoldenString() {
        #expect(SyncPairingInvite(vaultID: vaultID, pairingSecret: Self.secret, vaultKey: vaultKey).payload == Self.golden)
    }

    @Test func parsesWhatItBuilds() throws {
        let invite = try SyncPairingInvite(parsing: Self.golden)
        #expect(invite == SyncPairingInvite(vaultID: vaultID, pairingSecret: Self.secret, vaultKey: vaultKey))
    }

    @Test func theSecretHashIsTheBase64Sha256OfTheSecret() {
        let invite = SyncPairingInvite(vaultID: vaultID, pairingSecret: Self.secret, vaultKey: vaultKey)
        #expect(invite.secretHash == "icdGBFLt3/EZ/qBBnnhcdN4v+xOdvnQyOspKAeGYpdw=")
    }

    @Test func refusesAnythingElse() {
        let fields = Self.golden.dropFirst(SyncPairingInvite.prefix.count).split(separator: ":").map(String.init)
        let short = SyncCrypto.base64URL(Data(0..<15))
        let long = SyncCrypto.base64URL(Data(0..<65))
        func payload(_ parts: [String]) -> String { "thoughtreps-pair:v1:" + parts.joined(separator: ":") }
        let joined: String = fields.joined(separator: ":")
        var bad: [String] = ["", "thoughtreps-pair:v2:" + joined, "https://thoughtreps.com/pair?" + joined, "THOUGHTREPS-PAIR:V1:" + joined]
        bad += [Self.golden + ":extra", Self.golden + ":", Self.golden + " ", " " + Self.golden, Self.golden + "\n"]
        bad.append(payload([fields[0], fields[1]]))
        bad.append(payload(["short", fields[1], fields[2]]))
        bad.append(payload([fields[0], short, fields[2]]))
        bad.append(payload([fields[0], long, fields[2]]))
        bad.append(payload([fields[0], fields[1], String(fields[2].dropLast())]))
        bad.append(payload([fields[0], fields[1], fields[2] + "A"]))
        bad.append(payload([fields[0], fields[1] + "=", fields[2]]))
        bad.append(payload([fields[0], fields[1].replacingOccurrences(of: "E", with: "+"), fields[2]]))
        bad.append(payload([fields[0], fields[1], fields[2].replacingOccurrences(of: "A", with: "/")]))
        for text in bad {
            #expect(throws: SyncPairingInvite.Failure.malformed, "\(text)") { try SyncPairingInvite(parsing: text) }
        }
    }

    @Test func secretsFrom16To64BytesAreAccepted() throws {
        for count in [16, 32, 64] {
            let invite = SyncPairingInvite(vaultID: vaultID, pairingSecret: Data(repeating: 7, count: count), vaultKey: vaultKey)
            #expect(try SyncPairingInvite(parsing: invite.payload) == invite)
        }
    }
}

@Suite("Sync device name sealing")
struct SyncDeviceNameTests {
    static let nonce = Array(0xA0...0xAB).map { UInt8($0) }
    static let golden = "5452534ea0a1a2a3a4a5a6a7a8a9aaabba0263c3d2e9e6cd3ef3112eac6ea094d6e7381038924f35f25478f21a"
    static let name = "Nick's iPhone"

    func keys(_ key: Data = vaultKey) throws -> SyncKeys { try SyncKeys(vaultKey: key) }

    func sealed(_ name: String = name, vault: String = vaultID, key: String = keyID, keys: SyncKeys) throws -> Data {
        try SyncCrypto.sealDeviceName(name, vaultID: vault, keyID: key, keys: keys, nonce: AES.GCM.Nonce(data: Self.nonce))
    }

    @Test func sealsTheGoldenVector() throws {
        let frame = try sealed(keys: keys())
        #expect(frame.map { String(format: "%02x", $0) }.joined() == Self.golden)
        #expect(frame.prefix(4) == Data("TRSN".utf8) && frame.count == 4 + 12 + Self.name.utf8.count + 16)
    }

    @Test func opensTheGoldenVector() throws {
        let digits = Array(Self.golden)
        let frame = Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
        #expect(try SyncCrypto.openDeviceName(frame, vaultID: vaultID, keyID: keyID, keys: keys()) == Self.name)
    }

    @Test func theNameKeyIsItsOwnDerivation() throws {
        let derived = try keys()
        let raw = { (key: SymmetricKey) in key.withUnsafeBytes { Data($0) } }
        #expect(raw(derived.deviceName).map { String(format: "%02x", $0) }.joined() == "a30e2ac53638748fc7af1a7abd934f76e6a27002b221a8ae5f5f1f6ea5d2d966")
        #expect(raw(derived.deviceName) != raw(derived.record) && raw(derived.deviceName) != raw(derived.auth))
    }

    @Test func roundTripsWithRandomNonces() throws {
        let keys = try keys()
        let first = try SyncCrypto.sealDeviceName("Café 📱", vaultID: vaultID, keyID: keyID, keys: keys)
        let second = try SyncCrypto.sealDeviceName("Café 📱", vaultID: vaultID, keyID: keyID, keys: keys)
        #expect(first != second)
        #expect(try SyncCrypto.openDeviceName(first, vaultID: vaultID, keyID: keyID, keys: keys) == "Café 📱")
    }

    @Test func isBoundToTheVaultAndTheDevice() throws {
        let keys = try keys()
        let frame = try sealed(keys: keys)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openDeviceName(frame, vaultID: "other", keyID: keyID, keys: keys) }
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openDeviceName(frame, vaultID: vaultID, keyID: "other", keys: keys) }
        #expect(throws: SyncCrypto.Failure.decryptionFailed) {
            try SyncCrypto.openDeviceName(frame, vaultID: vaultID, keyID: keyID, keys: SyncKeys(vaultKey: Data(1..<33)))
        }
        // The fields are length-prefixed, so moving a character from one to the other is a different AAD.
        #expect(SyncCrypto.deviceNameAAD(vaultID: "ab", keyID: "c") != SyncCrypto.deviceNameAAD(vaultID: "a", keyID: "bc"))
    }

    @Test func aChangedFrameIsDamage() throws {
        let keys = try keys()
        var frame = try sealed(keys: keys)
        frame[frame.count - 1] ^= 1
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openDeviceName(frame, vaultID: vaultID, keyID: keyID, keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.openDeviceName(Data("TRSN".utf8), vaultID: vaultID, keyID: keyID, keys: keys) }
        var future = try sealed(keys: keys)
        future.replaceSubrange(0..<4, with: Data("TRSZ".utf8))
        #expect(throws: SyncCrypto.Failure.unrecognizedMagic) { try SyncCrypto.openDeviceName(future, vaultID: vaultID, keyID: keyID, keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(try sealed(keys: keys), vaultID: vaultID, recordKey: keyID, keys: keys) }
    }

    @Test func aLongNameIsCutOnACharacterBoundaryToFitTheServerLimit() throws {
        let keys = try keys()
        for unit in ["a", "é", "日", "📱", "👨‍👩‍👧‍👦"] {
            let long = String(repeating: unit, count: 400)
            let frame = try sealed(long, keys: keys)
            #expect(frame.count <= SyncCrypto.maxSealedDeviceNameBytes, "\(unit)")
            let opened = try SyncCrypto.openDeviceName(frame, vaultID: vaultID, keyID: keyID, keys: keys)
            #expect(!opened.isEmpty && long.hasPrefix(opened), "\(unit)")
            #expect(opened.allSatisfy { String($0) == unit }, "no half characters: \(unit)")
        }
        let exact = String(repeating: "a", count: 224)
        #expect(try sealed(exact, keys: keys).count == 256)
        #expect(try sealed(exact + "a", keys: keys).count == 256)
        #expect(try sealed("", keys: keys).count == 32)
    }
}

@Suite("Sync iCloud Keychain copy")
struct ICloudKeyCopyTests {
    final class MemoryCredentials: SyncCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: SyncCredentials?
        private(set) var saves = 0
        func load() throws -> SyncCredentials? { lock.withLock { value } }
        func save(_ credentials: SyncCredentials) throws { lock.withLock { value = credentials; saves += 1 } }
        func clear() { lock.withLock { value = nil } }
    }

    struct Failing: SyncCredentialStore {
        func load() throws -> SyncCredentials? { nil }
        func save(_ credentials: SyncCredentials) throws { throw KeychainStatusError(status: -25299) }
        func clear() {}
    }

    let held = SyncCredentials(vaultKey: vaultKey, vaultID: vaultID, userID: "user-1")

    func makeCopy(_ store: SyncCredentialStore = MemoryCredentials(), defaults: UserDefaults? = nil) -> ICloudKeyCopy {
        let suite = UserDefaults(suiteName: "ICloudKeyCopyTests.\(UUID().uuidString)")!
        return ICloudKeyCopy(store: store, defaults: defaults ?? suite)
    }

    @Test func isOnByDefault() {
        #expect(makeCopy().isEnabled)
    }

    @Test func savesWhenOnAndNotWhenOff() throws {
        let store = MemoryCredentials()
        let copy = makeCopy(store)
        try copy.saveIfEnabled(held)
        #expect(try store.load() == held)

        let off = MemoryCredentials()
        let disabled = makeCopy(off)
        try disabled.setEnabled(false, local: nil)
        try disabled.saveIfEnabled(held)
        #expect(try off.load() == nil && off.saves == 0)
    }

    @Test func turningItOffDeletesTheCopyAndOnWritesTheLocalKey() throws {
        let store = MemoryCredentials()
        let copy = makeCopy(store)
        try copy.saveIfEnabled(held)
        try copy.setEnabled(false, local: held)
        let afterOff = try store.load()
        #expect(!copy.isEnabled && afterOff == nil)
        try copy.setEnabled(true, local: held)
        let afterOn = try store.load()
        #expect(copy.isEnabled && afterOn == held)
    }

    @Test func turningItOnWithoutALocalKeyWritesNothing() throws {
        let store = MemoryCredentials()
        let copy = makeCopy(store)
        try copy.setEnabled(false, local: nil)
        try copy.setEnabled(true, local: nil)
        let stored = try store.load()
        #expect(copy.isEnabled && stored == nil && store.saves == 0)
    }

    @Test func theChoiceIsRememberedInTheDefaults() throws {
        let defaults = UserDefaults(suiteName: "ICloudKeyCopyTests.\(UUID().uuidString)")!
        try makeCopy(defaults: defaults).setEnabled(false, local: nil)
        #expect(!makeCopy(defaults: defaults).isEnabled)
    }

    @Test func deleteRemovesTheCopyEvenWhenOn() throws {
        let store = MemoryCredentials()
        let copy = makeCopy(store)
        try copy.saveIfEnabled(held)
        copy.delete()
        #expect(try copy.load() == nil && copy.isEnabled)
    }

    @Test func aFailedWriteSurfacesToTheCaller() {
        #expect(throws: KeychainStatusError.self) { try makeCopy(Failing()).saveIfEnabled(held) }
    }
}

@Suite("Join merge or erase")
struct JoinGateTests {
    @Test func everyJoinStartsWithTheConfirmation() {
        #expect(JoinGate.begin(thoughtCount: 0) == .confirmJoin(thoughtCount: 0))
        #expect(JoinGate.begin(thoughtCount: 3) == .confirmJoin(thoughtCount: 3))
    }

    @Test func confirmingAnEmptyLibraryJoinsWithoutAskingMore() {
        #expect(JoinGate.advance(.confirmJoin(thoughtCount: 0), .confirmJoin) == .join(eraseFirst: false))
    }

    @Test func confirmingALibraryWithThoughtsAsksMergeOrErase() {
        #expect(JoinGate.advance(.confirmJoin(thoughtCount: 3), .confirmJoin) == .askMergeOrErase(count: 3))
    }

    @Test func cancellingTheConfirmationJoinsNothingAndErasesNothing() {
        for count in [0, 3] {
            let step = JoinGate.advance(.confirmJoin(thoughtCount: count), .cancel)
            #expect(step == .cancelled)
        }
        for action in [JoinGate.Action.merge, .erase, .confirmErase] {
            #expect(JoinGate.advance(.confirmJoin(thoughtCount: 3), action) == .confirmJoin(thoughtCount: 3), "nothing skips the confirmation")
        }
    }

    @Test func theConfirmationTextIsPinned() {
        #expect(JoinGate.joinTitle == "Join this sync vault?")
        #expect(JoinGate.joinMessage == "Your thoughts on this device will be shared with the devices in it. Only continue with a code from your own device.")
    }

    @Test func mergeJoinsWithoutErasing() {
        #expect(JoinGate.advance(.askMergeOrErase(count: 3), .merge) == .join(eraseFirst: false))
    }

    @Test func eraseNeverJoinsWithoutASecondConfirmation() {
        let ask = JoinGate.Step.askMergeOrErase(count: 3)
        let confirm = JoinGate.advance(ask, .erase)
        #expect(confirm == .confirmErase(count: 3))
        #expect(JoinGate.advance(ask, .confirmErase) == ask, "the confirm button only counts on the confirmation")
        #expect(JoinGate.advance(confirm, .erase) == confirm)
        #expect(JoinGate.advance(confirm, .merge) == confirm)
        #expect(JoinGate.advance(confirm, .confirmErase) == .join(eraseFirst: true))
    }

    @Test func cancellingTheConfirmationReturnsToTheFirstPrompt() {
        #expect(JoinGate.advance(.confirmErase(count: 3), .cancel) == .askMergeOrErase(count: 3))
    }

    @Test func cancellingTheFirstPromptAbandonsTheJoin() {
        #expect(JoinGate.advance(.askMergeOrErase(count: 3), .cancel) == .cancelled)
    }

    @Test func aFinishedStepStaysFinished() {
        for step in [JoinGate.Step.join(eraseFirst: true), .cancelled] {
            for action in [JoinGate.Action.merge, .erase, .confirmErase, .cancel] {
                #expect(JoinGate.advance(step, action) == step)
            }
        }
    }

    @Test func theTextNamesTheDeviceAndTheCount() {
        #expect(JoinGate.askTitle(count: 1, device: "iPad") == "This iPad has 1 thought")
        #expect(JoinGate.askTitle(count: 12, device: "iPhone") == "This iPhone has 12 thoughts")
        #expect(JoinGate.askMessage(device: "iPad") == "Merge them with your synced thoughts, or erase this iPad first?")
        #expect(JoinGate.confirmTitle(count: 12, device: "iPhone") == "Erase 12 thoughts from this iPhone?")
        #expect(JoinGate.confirmMessage == "This can't be undone. Your synced thoughts aren't affected.")
    }
}
