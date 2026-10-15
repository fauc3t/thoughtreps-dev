import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync record codec")
struct SyncRecordCodecTests {
    let container: ModelContainer
    let store: ThoughtStore
    let now = Date(timeIntervalSince1970: 1_790_000_000.123_456)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves, ratingPrompt: .throwaway()
        )
        store.searchIndex = SearchIndex(location: .inMemory)
        self.store = store
    }

    func roundTrip(_ payload: SyncPayload) throws -> SyncPayload {
        try SyncPayload.decode(payload.encoded())
    }

    func makeThought() -> Thought {
        let inline = newImage(1)
        let target = store.create(body: "target", now: now).id
        let thought = store.create(
            body: "# Title #swift\n\(ImageToken.token(for: inline.id))",
            blocks: [
                BlockDraft(title: "Hidden", content: "secret #work", isBlurred: true),
                BlockDraft(kind: .gallery, title: "Pics", images: [newImage(2), newImage(3)]),
                BlockDraft(kind: .thoughtLink, linkedThoughtID: target),
                BlockDraft(kind: .file, file: fakeFile(4)),
            ],
            images: [inline], intervalDays: 3, now: now
        )
        store.markViewed(thought, now: now.addingTimeInterval(60))
        store.setPinned(thought, true, now: now.addingTimeInterval(120))
        return thought
    }

    @Test func contentRecordCarriesBodyBlocksAndImages() throws {
        let thought = makeThought()
        let record = ThoughtContentRecord(thought)
        #expect(record.id == thought.id)
        #expect(record.body == thought.body)
        #expect(record.updatedAt == thought.updatedAt)
        #expect(record.blocks.map(\.kindRaw) == ["markdown", "gallery", "thoughtLink", "file"])
        #expect(record.blocks[0].isBlurred)
        #expect(record.blocks[1].images.count == 2)
        #expect(record.blocks[3].file?.filename == "notes.pdf")
        #expect(record.images.count == 1)
        #expect(try roundTrip(.thoughtContent(record)) == .thoughtContent(record))
    }

    @Test func metaRecordCarriesScheduleStateAndCounters() throws {
        let thought = makeThought()
        let record = ThoughtMetaRecord(thought)
        #expect(record.isPinned)
        #expect(record.viewCount == 1)
        #expect(record.lastViewedAt == thought.lastViewedAt)
        #expect(record.intervalDays == 3)
        #expect(record.scheduleChangedAt == thought.scheduleChangedAt)
        #expect(record.stateChangedAt == thought.stateChangedAt)
        #expect(record.conflictOfID == nil)
        #expect(try roundTrip(.thoughtMeta(record)) == .thoughtMeta(record))
    }

    @Test func archivedLearnThoughtRoundTrips() throws {
        let thought = store.create(body: "learn me", learn: true, now: now)
        store.archive(thought, now: now.addingTimeInterval(5))
        thought.conflictOfID = UUID()
        thought.learnIntervalDays = 5
        let record = ThoughtMetaRecord(thought)
        #expect(record.isArchived && record.archivedAt != nil && record.intervalModeRaw == IntervalMode.learn.rawValue)
        #expect(try roundTrip(.thoughtMeta(record)) == .thoughtMeta(record))
    }

    @Test func tagAndSettingsRoundTrip() throws {
        let colored = TagRecord(name: "swift", displayName: "Swift", colorHex: "#3352D1", updatedAt: now)
        let implicit = TagRecord(name: "work", displayName: "Work", colorHex: nil, updatedAt: .distantPast)
        let settings = SettingsRecord(defaultIntervalDays: 14, changedAt: now)
        let never = SettingsRecord(defaultIntervalDays: 7, changedAt: .distantPast)
        for payload in [SyncPayload.tag(colored), .tag(implicit), .settings(settings), .settings(never)] {
            #expect(try roundTrip(payload) == payload)
        }
    }

    @Test func deletionRoundTripsForBothThoughtRecords() throws {
        let deletion = SyncDeletion(id: UUID(), deletedAt: now)
        for type in [SyncRecordType.thoughtContent, .thoughtMeta] {
            let payload = SyncPayload.deletion(type, deletion)
            let decoded = try roundTrip(payload)
            #expect(decoded == payload)
            #expect(decoded.isDeletion && decoded.type == type && decoded.entityID == deletion.id.uuidString)
        }
        let json = try #require(String(data: SyncPayload.deletion(.thoughtMeta, deletion).encoded(), encoding: .utf8))
        #expect(json.contains("\"deleted\":true") && json.contains("\"v\":1"))
    }

    @Test func aDeletionOfATagIsRejected() throws {
        let json = #"{"v":1,"type":"tag","deleted":true,"data":{"id":"6C9B3F5E-2B7A-4F57-9D0A-0F0B7C1E1A11","deletedAt":"2026-01-01T00:00:00.000Z"}}"#
        #expect(throws: SyncPayload.Failure.invalid) { try SyncPayload.decode(Data(json.utf8)) }
    }

    @Test func newerVersionAndUnknownTypeAreRefused() throws {
        let newer = #"{"v":2,"type":"settings","deleted":false,"data":{}}"#
        #expect(throws: SyncPayload.Failure.unsupportedVersion(2)) { try SyncPayload.decode(Data(newer.utf8)) }
        let unknown = #"{"v":1,"type":"widget","deleted":false,"data":{}}"#
        #expect(throws: SyncPayload.Failure.unknownType("widget")) { try SyncPayload.decode(Data(unknown.utf8)) }
    }

    @Test func bytesAndHashAreStable() throws {
        let thought = makeThought()
        let first = try SyncPayload.thoughtContent(ThoughtContentRecord(thought)).encoded()
        let second = try SyncPayload.thoughtContent(ThoughtContentRecord(thought)).encoded()
        #expect(first == second)
        #expect(SyncPayload.hash(of: first) == SyncPayload.hash(of: second))
        #expect(SyncPayload.hash(of: first).count == 64)
        thought.updatedAt = thought.updatedAt.addingTimeInterval(1)
        let edited = try SyncPayload.thoughtContent(ThoughtContentRecord(thought)).encoded()
        #expect(SyncPayload.hash(of: edited) != SyncPayload.hash(of: first))
    }

    @Test func fingerprintSurvivesTheWire() throws {
        let thought = makeThought()
        for payload in [
            SyncPayload.thoughtContent(ThoughtContentRecord(thought)), .thoughtMeta(ThoughtMetaRecord(thought)),
            .tag(TagRecord(name: "a", displayName: "A", colorHex: nil, updatedAt: now)), .settings(SettingsRecord(defaultIntervalDays: 7, changedAt: now)),
            .deletion(.thoughtContent, SyncDeletion(id: UUID(), deletedAt: now)),
        ] {
            #expect(try roundTrip(payload).fingerprint == payload.fingerprint)
        }
    }

    @Test func datesRoundTripExactly() throws {
        var rng = SeededGenerator(seed: 99)
        var dates = [
            Date(timeIntervalSinceReferenceDate: 800_000_144.3445544), .distantPast, .distantFuture, Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSinceReferenceDate: -1e-9), Date(timeIntervalSinceReferenceDate: -123_456_789.987_654_3),
        ]
        for _ in 0..<20_000 {
            let whole = Double(Int.random(in: -1_000_000_000...1_000_000_000, using: &rng))
            dates.append(Date(timeIntervalSinceReferenceDate: whole + Double.random(in: 0..<1, using: &rng)))
            let edge = Double(Int.random(in: 0..<1000, using: &rng)) / 1000
            dates.append(Date(timeIntervalSinceReferenceDate: whole + edge + Double.random(in: -0.000_001...0.000_001, using: &rng)))
        }
        for date in dates {
            let applied = try SyncPayload.decoder().decode([Date].self, from: SyncPayload.encoder().encode([date]))[0]
            #expect(applied == date)
            #expect(SyncFingerprint.exact(applied) == SyncFingerprint.exact(date))
        }
        #expect(SyncFingerprint.exact(Date(timeIntervalSinceReferenceDate: 1)) != SyncFingerprint.exact(Date(timeIntervalSinceReferenceDate: 1.000_000_001)))
    }

    @Test func subMillisecondClocksFingerprintTheSameAfterTheWire() throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_144.3445544)
        let payload = SyncPayload.thoughtMeta(ThoughtMetaRecord(
            id: UUID(), nextDueAt: date, intervalDays: nil, intervalModeRaw: "fixed", learnIntervalDays: nil, scheduleChangedAt: date,
            isPinned: false, isArchived: false, archivedAt: nil, conflictOfID: nil, stateChangedAt: date, viewCount: 1, lastViewedAt: date
        ))
        #expect(try roundTrip(payload).fingerprint == payload.fingerprint)
    }

    @Test func fingerprintsFollowTheirClocks() {
        let base = SyncFingerprint.meta(scheduleChangedAt: now, stateChangedAt: now, viewCount: 1, lastViewedAt: now)
        #expect(base != SyncFingerprint.meta(scheduleChangedAt: now.addingTimeInterval(1), stateChangedAt: now, viewCount: 1, lastViewedAt: now))
        #expect(base != SyncFingerprint.meta(scheduleChangedAt: now, stateChangedAt: now.addingTimeInterval(1), viewCount: 1, lastViewedAt: now))
        #expect(base != SyncFingerprint.meta(scheduleChangedAt: now, stateChangedAt: now, viewCount: 2, lastViewedAt: now))
        #expect(base != SyncFingerprint.meta(scheduleChangedAt: now, stateChangedAt: now, viewCount: 1, lastViewedAt: nil))
        #expect(SyncFingerprint.content(updatedAt: now) != SyncFingerprint.content(updatedAt: now.addingTimeInterval(1)))
        #expect(SyncFingerprint.deletion(deletedAt: now) != SyncFingerprint.content(updatedAt: now))
    }
}

@Suite("Sync encryption")
struct SyncCryptoTests {
    static let vaultKey = Data((0..<32).map { UInt8($0) })
    let keys = try! SyncKeys(vaultKey: SyncCryptoTests.vaultKey)
    let plaintext = Data("{\"v\":1}".utf8)

    static var vaultKey2: Data { Data((0..<32).map { UInt8(255 - $0) }) }

    func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    @Test func keysAreDistinctAndDeterministic() throws {
        let all = [keys.record, keys.blob, keys.index, keys.auth].map(bytes)
        #expect(Set(all).count == 4)
        #expect(all.allSatisfy { $0.count == 32 })
        let again = try SyncKeys(vaultKey: Self.vaultKey)
        #expect([again.record, again.blob, again.index, again.auth].map(bytes) == all)
        let other = try SyncKeys(vaultKey: Self.vaultKey2)
        #expect(bytes(other.record) != bytes(keys.record))
    }

    @Test func vaultKeyMustBe32Bytes() {
        #expect(throws: SyncKeys.Failure.badKeyLength) { try SyncKeys(vaultKey: Data(count: 16)) }
    }

    @Test func roundTrip() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        #expect(sealed.prefix(4) == Data("TRS1".utf8))
        #expect(sealed[4] == SyncCrypto.currentKeyGeneration)
        #expect(sealed[5] == 1)
        #expect(sealed.count == 512, "a short record is padded to the smallest bucket")
        let opened = try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys)
        #expect(opened == SyncCrypto.Opened(payloadVersion: 1, plaintext: plaintext))
    }

    @Test func eachSealUsesAFreshNonce() throws {
        let one = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        let two = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        #expect(one != two)
    }

    @Test func wrongKeyFails() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        let other = try SyncKeys(vaultKey: Self.vaultKey2)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: other) }
    }

    @Test func aCiphertextMovedToAnotherRecordOrVaultFails() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "other", keys: keys) }
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(sealed, vaultID: "w", recordKey: "rk", keys: keys) }
    }

    @Test func aadIsUnambiguousAcrossFields() throws {
        #expect(
            SyncCrypto.recordAAD(vaultID: "A|B", recordKey: "K", payloadVersion: 1)
                != SyncCrypto.recordAAD(vaultID: "A", recordKey: "B|K", payloadVersion: 1)
        )
        #expect(SyncCrypto.blobAAD(vaultID: "A|B", name: "K") != SyncCrypto.blobAAD(vaultID: "A", name: "B|K"))
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "A|B", recordKey: "K", payloadVersion: 1, keys: keys)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(sealed, vaultID: "A", recordKey: "B|K", keys: keys) }
    }

    @Test func aChangedVersionByteFails() throws {
        var sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        sealed[5] = 2
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys) }
    }

    @Test func tamperingWithAnyByteFails() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        for index in 5..<sealed.count {
            var changed = sealed
            changed[index] ^= 0x01
            #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.open(changed, vaultID: "v", recordKey: "rk", keys: keys) }
        }
    }

    @Test func badFramesAreRecognized() throws {
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(Data("short".utf8), vaultID: "v", recordKey: "rk", keys: keys) }
        var sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        sealed.replaceSubrange(0..<4, with: Data("XXXX".utf8))
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys) }
        #expect(throws: SyncCrypto.Failure.invalidVersion) {
            try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 300, keys: keys)
        }
    }

    @Test func recordKeysAreDeterministicOpaqueAndSeparatedByTypeAndVault() throws {
        let id = UUID().uuidString
        let key = keys.recordKey(type: .thoughtContent, entityID: id)
        #expect(key == keys.recordKey(type: .thoughtContent, entityID: id))
        #expect(key != keys.recordKey(type: .thoughtMeta, entityID: id))
        #expect(key != keys.recordKey(type: .thoughtContent, entityID: UUID().uuidString))
        #expect(key != keys.recordKey(type: .tag, entityID: id))
        let other = try SyncKeys(vaultKey: Self.vaultKey2)
        #expect(key != other.recordKey(type: .thoughtContent, entityID: id))
        #expect(key.count == 43)
        #expect(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(!key.contains(id))
    }

    @Test func framesLandOnSizeBuckets() throws {
        func sealedCount(_ bytes: Int) throws -> Int {
            try SyncCrypto.seal(Data(repeating: 7, count: bytes), vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys).count
        }
        let room = 512 - SyncCrypto.overheadBytes - SyncCrypto.lengthPrefixBytes
        #expect(try sealedCount(0) == 512)
        #expect(try sealedCount(room) == 512)
        #expect(try sealedCount(room + 1) == 1024)
        #expect(try sealedCount(5_000) == 8192)
        #expect(try sealedCount(65_536 - SyncCrypto.overheadBytes - SyncCrypto.lengthPrefixBytes) == 65_536, "a full bucket still fits inline")
        #expect(try sealedCount(1_048_576 - SyncCrypto.overheadBytes - SyncCrypto.lengthPrefixBytes) == 1_048_576)
        #expect(try sealedCount(1_048_576) == 2 * 1_048_576, "past 1 MiB the steps are whole MiB")
        #expect(try sealedCount(3 * 1_048_576 + 5) == 4 * 1_048_576)
        #expect(SyncCrypto.bucket(forFrameBytes: 1) == 512)
    }

    @Test func paddingIsInsideTheCiphertextAndTheLengthComesBack() throws {
        for size in [0, 1, 100, 470, 471, 472, 600, 4000, 70_000] {
            let data = Data((0..<size).map { UInt8($0 % 251) })
            let sealed = try SyncCrypto.seal(data, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
            let opened = try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys)
            #expect(opened.plaintext == data, "size \(size)")
        }
    }

    @Test func theHashIgnoresPadding() throws {
        let short = Data("{\"a\":1}".utf8)
        let opened = try SyncCrypto.open(
            SyncCrypto.seal(short, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys), vaultID: "v", recordKey: "rk", keys: keys
        )
        #expect(SyncPayload.hash(of: opened.plaintext) == SyncPayload.hash(of: short))
    }

    @Test func anUnrecognizedFrameMagicIsANewerFormatNotDamage() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        for magic in ["TRS2", "TRP2", "TRX9", "TRSC"] {
            var future = sealed
            future.replaceSubrange(0..<4, with: Data(magic.utf8))
            #expect(throws: SyncCrypto.Failure.unrecognizedMagic, "\(magic)") { try SyncCrypto.open(future, vaultID: "v", recordKey: "rk", keys: keys) }
            #expect(throws: SyncCrypto.Failure.unrecognizedMagic, "\(magic)") { try SyncCrypto.openBlob(future, vaultID: "v", name: "n", keys: keys) }
        }
        #expect(throws: SyncCrypto.Failure.unrecognizedMagic) { try SyncCrypto.open(Data("TRS2".utf8), vaultID: "v", recordKey: "rk", keys: keys) }
        for magic in ["XXXX", "tr01", "\0\0\0\0"] {
            var damaged = sealed
            damaged.replaceSubrange(0..<min(4, magic.utf8.count), with: Data(magic.utf8).prefix(4))
            #expect(throws: SyncCrypto.Failure.badFormat, "\(magic)") { try SyncCrypto.open(damaged, vaultID: "v", recordKey: "rk", keys: keys) }
        }
    }

    @Test func anAuthenticFrameWithAForgedLengthPrefixIsBadFormat() throws {
        let padded = Data([0x7f, 0xff, 0xff, 0xff]) + Data(count: 100)
        let box = try AES.GCM.seal(
            padded, using: keys.record, authenticating: SyncCrypto.recordAAD(vaultID: "v", recordKey: "rk", payloadVersion: 1)
        )
        var frame = Data("TRS1".utf8) + Data([SyncCrypto.currentKeyGeneration, 1])
        frame += box.nonce + box.ciphertext + box.tag
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(frame, vaultID: "v", recordKey: "rk", keys: keys) }
    }

    @Test func aKnownMagicInTheWrongPlaceIsDamage() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        let blob = try SyncCrypto.sealBlob(plaintext, vaultID: "v", name: "n", keys: keys)
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(blob, vaultID: "v", recordKey: "rk", keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.openBlob(sealed, vaultID: "v", name: "n", keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) {
            try SyncCrypto.open(SyncCrypto.pointer(toBlob: keys.blobName(kind: .image, id: UUID())), vaultID: "v", recordKey: "rk", keys: keys)
        }
    }

    @Test func aNewerKeyGenerationIsParkedNotDamage() throws {
        var sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "rk", payloadVersion: 1, keys: keys)
        sealed[4] = 2
        #expect(throws: SyncCrypto.Failure.unsupportedKeyGeneration(2)) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys) }
        var blob = try SyncCrypto.sealBlob(plaintext, vaultID: "v", name: "n", keys: keys)
        blob[4] = 9
        #expect(throws: SyncCrypto.Failure.unsupportedKeyGeneration(9)) { try SyncCrypto.openBlob(blob, vaultID: "v", name: "n", keys: keys) }
        sealed[4] = 0
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(sealed, vaultID: "v", recordKey: "rk", keys: keys) }
    }

    @Test func theKeyGenerationIsBoundIntoTheAAD() {
        var other = SyncCrypto.recordAAD(vaultID: "v", recordKey: "rk", payloadVersion: 1)
        #expect(other.last == SyncCrypto.currentKeyGeneration)
        other[other.count - 1] = 2
        #expect(other != SyncCrypto.recordAAD(vaultID: "v", recordKey: "rk", payloadVersion: 1))
        #expect(SyncCrypto.blobAAD(vaultID: "v", name: "n").last == SyncCrypto.currentKeyGeneration)
    }

    // MARK: Blobs

    @Test func aBlobRoundTrips() throws {
        let data = Data((0..<1000).map { UInt8($0 % 256) })
        let sealed = try SyncCrypto.sealBlob(data, vaultID: "v", name: "n", keys: keys)
        #expect(sealed.prefix(4) == Data("TRSB".utf8))
        #expect(sealed[4] == SyncCrypto.currentKeyGeneration)
        #expect(sealed.count == data.count + SyncCrypto.blobOverheadBytes, "blobs aren't padded")
        #expect(try SyncCrypto.openBlob(sealed, vaultID: "v", name: "n", keys: keys) == data)
        #expect(try SyncCrypto.openBlob(SyncCrypto.sealBlob(Data(), vaultID: "v", name: "n", keys: keys), vaultID: "v", name: "n", keys: keys) == Data())
    }

    @Test func aBlobFailsUnderAnotherVaultNameOrKey() throws {
        let sealed = try SyncCrypto.sealBlob(Data("pixels".utf8), vaultID: "v", name: "n", keys: keys)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openBlob(sealed, vaultID: "w", name: "n", keys: keys) }
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openBlob(sealed, vaultID: "v", name: "m", keys: keys) }
        let other = try SyncKeys(vaultKey: Self.vaultKey2)
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openBlob(sealed, vaultID: "v", name: "n", keys: other) }
    }

    @Test func tamperingWithAnyBlobByteFails() throws {
        let sealed = try SyncCrypto.sealBlob(Data("pixels and more pixels".utf8), vaultID: "v", name: "n", keys: keys)
        for index in 5..<sealed.count {
            var changed = sealed
            changed[index] ^= 0x01
            #expect(throws: SyncCrypto.Failure.decryptionFailed, "byte \(index)") { try SyncCrypto.openBlob(changed, vaultID: "v", name: "n", keys: keys) }
        }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.openBlob(sealed.prefix(20), vaultID: "v", name: "n", keys: keys) }
    }

    @Test func aBlobAndARecordAreNotInterchangeable() throws {
        let sealed = try SyncCrypto.seal(plaintext, vaultID: "v", recordKey: "n", payloadVersion: 1, keys: keys)
        let blob = try SyncCrypto.sealBlob(plaintext, vaultID: "v", name: "n", keys: keys)
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.openBlob(sealed, vaultID: "v", name: "n", keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.open(blob, vaultID: "v", recordKey: "n", keys: keys) }
    }

    @Test func blobNamesAreSeparatedByDomain() throws {
        let id = UUID()
        let image = keys.blobName(kind: .image, id: id)
        let file = keys.blobName(kind: .file, id: id)
        let recordKey = keys.recordKey(type: .thoughtContent, entityID: id.uuidString)
        let record = keys.recordBlobName(recordKey: recordKey, hash: "abc")
        #expect(Set([image, file, record, recordKey]).count == 4)
        #expect(record == keys.recordBlobName(recordKey: recordKey, hash: "abc"))
        #expect(record != keys.recordBlobName(recordKey: recordKey, hash: "abd"))
        #expect(record != keys.recordBlobName(recordKey: keys.recordKey(type: .thoughtMeta, entityID: id.uuidString), hash: "abc"))
        #expect(record != keys.recordBlobName(recordKey: "abc", hash: recordKey), "the inputs aren't interchangeable")
        let other = try SyncKeys(vaultKey: Self.vaultKey2)
        #expect(record != other.recordBlobName(recordKey: recordKey, hash: "abc"))
        #expect([image, file, record].allSatisfy { $0.count == SyncCrypto.blobNameLength })
    }

    @Test func aPointerMustNameExactlyOneWellFormedBlob() throws {
        let name = keys.blobName(kind: .image, id: UUID())
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: name)) == name)
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: String(name.dropLast()))) == nil)
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: name + "A")) == nil)
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: "../" + String(name.dropFirst(3)))) == nil)
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: String(name.dropLast()) + "=")) == nil)
        #expect(SyncCrypto.blobName(inPointer: SyncCrypto.pointer(toBlob: String(name.dropLast()) + "+")) == nil)
        #expect(SyncCrypto.blobName(inPointer: Data("TRP2".utf8) + Data(name.utf8)) == nil)
        #expect(SyncCrypto.blobName(inPointer: Data("TRP1".utf8)) == nil)
    }

    @Test func aSealedPayloadOpensToTheSameRecord() throws {
        let payload = SyncPayload.settings(SettingsRecord(defaultIntervalDays: 10, changedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        let key = keys.recordKey(type: payload.type, entityID: payload.entityID)
        let sealed = try SyncCrypto.seal(payload.encoded(), vaultID: "v", recordKey: key, payloadVersion: SyncPayload.currentVersion, keys: keys)
        let opened = try SyncCrypto.open(sealed, vaultID: "v", recordKey: key, keys: keys)
        #expect(try SyncPayload.decode(opened.plaintext) == payload)
    }
}
