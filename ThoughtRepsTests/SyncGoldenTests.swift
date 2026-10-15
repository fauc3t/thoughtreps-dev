import CryptoKit
import Foundation
import Testing
@testable import ThoughtReps

@Suite("Sync wire format known answers")
struct SyncGoldenTests {
    static let vaultKey = Data((0..<32).map { UInt8($0) })
    let keys = try! SyncKeys(vaultKey: SyncGoldenTests.vaultKey)
    static let entity = "11111111-2222-3333-4444-555555555555"
    static let recordKey = "qz6UTEzyJFbDPBPs7gT7nfPG1mKKBOG20H4EfmBsMWo"
    static let nonce = Data(0..<12)

    func bytes(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func derivedKeysNeverChange() {
        #expect(bytes(keys.record) == "b8b47d22954de7ae33554748e67ed7d77fc34714f823f0375b3dd40f331ded95")
        #expect(bytes(keys.blob) == "b3edd044d4789deb1b54b31c448092721e46f77249379651e513f3fb4de41181")
        #expect(bytes(keys.index) == "f3f8a27a14b0643e644185a9ee2e2d6e1db19d51799f573a7c6ca22b8ff1b6c1")
        #expect(bytes(keys.auth) == "5f50425a8e159cee5cd170578520296b6e88eedf8500a80b093efb091a6c6311")
    }

    @Test func namesNeverChange() throws {
        #expect(keys.recordKey(type: .thoughtContent, entityID: Self.entity) == Self.recordKey)
        let id = try #require(UUID(uuidString: Self.entity))
        #expect(keys.blobName(kind: .image, id: id) == "oN0oqjn2bcb3szTTzvsQ5HX8buFEW20y7W7IeERc6V8")
        #expect(keys.blobName(kind: .file, id: id) == "PIJBsLvhYYOSoJO94ip0nqdPARcBKbAXmFxmfIO_7uk")
        #expect(keys.recordBlobName(recordKey: Self.recordKey, hash: String(repeating: "ab", count: 32)) == "Y3rJMIoeIXvR4DjI-KRhwXC0GV-TqQ-tujMe2UKlAnU")
    }

    @Test func aadBytesNeverChange() {
        #expect(
            hex(SyncCrypto.recordAAD(vaultID: "vault-1", recordKey: Self.recordKey, payloadVersion: 1))
                == "000000077661756c742d310000002b717a365554457a794a46624450425073376754376e665047316d4b4b424f473230483445666d42734d576f0000000101"
        )
        #expect(
            hex(SyncCrypto.blobAAD(vaultID: "vault-1", name: "oN0oqjn2bcb3szTTzvsQ5HX8buFEW20y7W7IeERc6V8"))
                == "000000077661756c742d310000002b6f4e306f716a6e3262636233737a54547a767351354858386275464557323079375737496545526336563801"
        )
    }

    // MARK: Payload JSON

    static let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func json(_ payload: SyncPayload) throws -> String {
        String(decoding: try payload.encoded(), as: UTF8.self)
    }

    @Test func contentPayloadBytesNeverChange() throws {
        let image = ImageRecord(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, width: 40, height: 30, order: 0)
        let blocks = [
            BlockRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, kindRaw: "markdown", title: "T", content: "secret", order: 0,
                isBlurred: true, images: []
            ),
            BlockRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, kindRaw: "file", title: nil, content: "", order: 1, images: [],
                file: FileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!, filename: "a.txt", typeIdentifier: "public.plain-text", byteCount: 3)
            ),
            BlockRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!, kindRaw: "thoughtLink", title: nil, content: "", order: 2, images: [],
                linkedThoughtID: Self.id2
            ),
            BlockRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!, kindRaw: "gallery", title: nil, content: "", order: 3, images: [image]
            ),
        ]
        let content = ThoughtContentRecord(
            id: Self.id1, body: "hi #a", createdAt: date(100), updatedAt: date(200.5), blocks: blocks, images: [image]
        )
        let expected = #"{"data":{"blocks":[{"content":"secret","id":"00000000-0000-0000-0000-0000000000B1","images":[],"isBlurred":true,"kindRaw":"markdown","order":0,"title":"T"},{"content":"","file":{"byteCount":3,"filename":"a.txt","id":"00000000-0000-0000-0000-0000000000F1","typeIdentifier":"public.plain-text"},"id":"00000000-0000-0000-0000-0000000000B2","images":[],"isBlurred":false,"kindRaw":"file","order":1},{"content":"","id":"00000000-0000-0000-0000-0000000000B3","images":[],"isBlurred":false,"kindRaw":"thoughtLink","linkedThoughtID":"00000000-0000-0000-0000-000000000002","order":2},{"content":"","id":"00000000-0000-0000-0000-0000000000B4","images":[{"height":30,"id":"00000000-0000-0000-0000-0000000000A1","order":0,"width":40}],"isBlurred":false,"kindRaw":"gallery","order":3}],"body":"hi #a","createdAt":100,"id":"00000000-0000-0000-0000-000000000001","images":[{"height":30,"id":"00000000-0000-0000-0000-0000000000A1","order":0,"width":40}],"updatedAt":200.5},"deleted":false,"type":"thought.content","v":1}"#
        #expect(try json(.thoughtContent(content)) == expected)
        #expect(try SyncPayload.decode(Data(expected.utf8)) == .thoughtContent(content))
    }

    @Test func metaPayloadBytesNeverChange() throws {
        let meta = ThoughtMetaRecord(
            id: Self.id2, nextDueAt: date(1000), intervalDays: 7, intervalModeRaw: "fixed", learnIntervalDays: nil, scheduleChangedAt: date(400),
            isPinned: true, isArchived: false, archivedAt: nil, conflictOfID: nil, stateChangedAt: date(500), viewCount: 2, lastViewedAt: date(300)
        )
        let expected = #"{"data":{"id":"00000000-0000-0000-0000-000000000002","intervalDays":7,"intervalModeRaw":"fixed","isArchived":false,"isPinned":true,"lastViewedAt":300,"nextDueAt":1000,"scheduleChangedAt":400,"stateChangedAt":500,"viewCount":2},"deleted":false,"type":"thought.meta","v":1}"#
        #expect(try json(.thoughtMeta(meta)) == expected)
        #expect(try SyncPayload.decode(Data(expected.utf8)) == .thoughtMeta(meta))
    }

    @Test func tagSettingsAndDeletionPayloadBytesNeverChange() throws {
        let tag = TagRecord(name: "swift", displayName: "Swift", colorHex: "#3352D1", updatedAt: date(50))
        let tagJSON = ##"{"data":{"colorHex":"#3352D1","displayName":"Swift","name":"swift","updatedAt":50},"deleted":false,"type":"tag","v":1}"##
        #expect(try json(.tag(tag)) == tagJSON)
        #expect(try SyncPayload.decode(Data(tagJSON.utf8)) == .tag(tag))

        let implicit = TagRecord(name: "work", displayName: "Work", colorHex: nil, updatedAt: nil)
        #expect(try json(.tag(implicit)) == #"{"data":{"displayName":"Work","name":"work"},"deleted":false,"type":"tag","v":1}"#)

        let settings = SettingsRecord(defaultIntervalDays: 14, changedAt: date(10))
        let settingsJSON = #"{"data":{"changedAt":10,"defaultIntervalDays":14},"deleted":false,"type":"settings","v":1}"#
        #expect(try json(.settings(settings)) == settingsJSON)
        #expect(try SyncPayload.decode(Data(settingsJSON.utf8)) == .settings(settings))

        let deletion = SyncDeletion(id: Self.id1, deletedAt: date(60))
        let deletionJSON = #"{"data":{"deletedAt":60,"id":"00000000-0000-0000-0000-000000000001"},"deleted":true,"type":"thought.meta","v":1}"#
        #expect(try json(.deletion(.thoughtMeta, deletion)) == deletionJSON)
        #expect(try SyncPayload.decode(Data(deletionJSON.utf8)) == .deletion(.thoughtMeta, deletion))
    }

    /// Every key path of the JSON, so a field added to the backup record that the wire struct doesn't map shows up.
    func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.flatMap { key, child in [prefix + key] + keyPaths(child, prefix: prefix + key + ".") })
        }
        if let array = value as? [Any] { return Set(array.flatMap { keyPaths($0, prefix: prefix) }) }
        return []
    }

    func keys<T: Encodable>(_ value: T, with encoder: JSONEncoder) throws -> Set<String> {
        keyPaths(try JSONSerialization.jsonObject(with: encoder.encode(value)))
    }

    @Test func theWireStructsMapEveryFieldOfTheBackupRecords() throws {
        let image = ImageRecord(id: Self.id1, width: 1, height: 2, order: 3)
        let file = FileRecord(id: Self.id1, filename: "a", typeIdentifier: "t", byteCount: 1)
        let block = BlockRecord(
            id: Self.id1, kindRaw: "file", title: "t", content: "c", order: 1, isBlurred: true, images: [image], linkedThoughtID: Self.id2, file: file
        )
        let tag = TagRecord(name: "a", displayName: "A", colorHex: "#000000", updatedAt: date(1))
        let thought = ThoughtRecord(
            id: Self.id1, body: "b", createdAt: date(1), updatedAt: date(2), scheduleChangedAt: date(3), stateChangedAt: date(4),
            nextDueAt: date(5), lastViewedAt: date(6), viewCount: 1, intervalDays: 2, intervalModeRaw: "fixed", learnIntervalDays: 3,
            isPinned: true, isArchived: true, archivedAt: date(7), conflictOfID: Self.id2, tags: ["a"], blocks: [block], images: [image]
        )
        let backup = BackupFormat.encoder()
        let wire = SyncPayload.encoder()
        #expect(try keys(block, with: backup) == keys(SyncWireV1.Block(block), with: wire))
        #expect(try keys(tag, with: backup) == keys(SyncWireV1.Tag(tag), with: wire))
        let thoughtOnlyFields: Set<String> = [
            "scheduleChangedAt", "stateChangedAt", "nextDueAt", "lastViewedAt", "viewCount", "intervalDays", "intervalModeRaw",
            "learnIntervalDays", "isPinned", "isArchived", "archivedAt", "conflictOfID", "tags",
        ]
        let content = SyncWireV1.Content(ThoughtContentRecord(thought))
        #expect(try keys(thought, with: backup).subtracting(thoughtOnlyFields) == keys(content, with: wire))
    }

    @Test func aBlockWithoutIsBlurredStillDecodes() throws {
        let json = #"{"content":"c","id":"00000000-0000-0000-0000-0000000000B1","images":[],"kindRaw":"markdown","order":0}"#
        let block = try SyncPayload.decoder().decode(SyncWireV1.Block.self, from: Data(json.utf8))
        #expect(block.isBlurred == false)
    }

    @Test func theHashIsOfTheUnpaddedPlaintext() throws {
        let plaintext = Data(#"{"data":{"changedAt":10,"defaultIntervalDays":14},"deleted":false,"type":"settings","v":1}"#.utf8)
        #expect(SyncPayload.hash(of: plaintext) == SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Frames

    static let settingsPlaintext = Data(#"{"data":{"changedAt":10,"defaultIntervalDays":14},"deleted":false,"type":"settings","v":1}"#.utf8)

    @Test func aSealedRecordFrameNeverChanges() throws {
        let nonce = try AES.GCM.Nonce(data: Self.nonce)
        let frame = try SyncCrypto.seal(
            Self.settingsPlaintext, vaultID: "vault-1", recordKey: Self.recordKey, payloadVersion: 1, keys: keys, nonce: nonce
        )
        #expect(frame.count == 512)
        #expect(hex(frame.prefix(18)) == "54525331" + "01" + "01" + "000102030405060708090a0b")
        #expect(Self.frameDigest == SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined())
        let opened = try SyncCrypto.open(frame, vaultID: "vault-1", recordKey: Self.recordKey, keys: keys)
        #expect(opened == SyncCrypto.Opened(payloadVersion: 1, plaintext: Self.settingsPlaintext))
    }

    @Test func aStoredRecordFrameStillOpens() throws {
        let frame = try #require(Data(base64Encoded: Self.storedFrame))
        let opened = try SyncCrypto.open(frame, vaultID: "vault-1", recordKey: Self.recordKey, keys: keys)
        #expect(opened == SyncCrypto.Opened(payloadVersion: 1, plaintext: Self.settingsPlaintext))
    }

    @Test func aSealedBlobFrameNeverChanges() throws {
        let name = "oN0oqjn2bcb3szTTzvsQ5HX8buFEW20y7W7IeERc6V8"
        let nonce = try AES.GCM.Nonce(data: Self.nonce)
        let frame = try SyncCrypto.sealBlob(Data("pixels".utf8), vaultID: "vault-1", name: name, keys: keys, nonce: nonce)
        #expect(frame.count == 6 + SyncCrypto.blobOverheadBytes)
        #expect(hex(frame.prefix(17)) == "54525342" + "01" + "000102030405060708090a0b")
        #expect(hex(frame) == Self.blobFrameHex)
        #expect(try SyncCrypto.openBlob(frame, vaultID: "vault-1", name: name, keys: keys) == Data("pixels".utf8))
    }

    @Test func aPointerIsTheMagicAndTheName() throws {
        let name = "oN0oqjn2bcb3szTTzvsQ5HX8buFEW20y7W7IeERc6V8"
        let pointer = SyncCrypto.pointer(toBlob: name)
        #expect(pointer == Data("TRP1\(name)".utf8))
        #expect(SyncCrypto.blobName(inPointer: pointer) == name)
    }

    static let frameDigest = "8a4cccddb01895fa267df076cf77ead76febe8500716a3c4868bea1a34fd90b5"
    static let storedFrame = "VFJTMQEBAAECAwQFBgcICQoLy8dEEk9Y4EU0OmrtujFxdmlP8fp7/vmoK68dBuCgHmund0oMoK4i4/kJz/lSPKOEf+R0y3eV1W6KcPrmU/A3h3Yz3de+vzFIBs+apgzGvqp05kESTcuRESQYEyE31FB4aYyW5IfmLOEtLAPTMZ4l5v13d4a++KwABtSud6uu5bAirlc1fZZRiL5UgDqoGyW5S/qR/9At/VHjYo2mA0YvpRk9SWy6aebKDEDKiO9Xg3eKYdb3msmkxejzoKx6VmFJP9vU7UcV5g8+HKH3AQw53kKqLvhHh/Sn25ZtNS+WVdzU6hsZacusBPcq6CjkoMoPnm9X23ahU6hcaBnANY71xbZRT9Tq0x29bhrf+6iQsleekwvniktAtZJkoUioI5yMCiGw+wx5GIntnKQfbYcDzs6VafaMdCgMZOsnwvGn2uHqqsN2/92PBwDYfqGBjcEurireWOTHAKu7/NzWVAR7jIRK/eWAyeIIeArmIRGI6TgSgo9gCL179/c2ORBU2JwEXnAXEbXGsl59su58AwBl6zD5ZnJFsURJ1Es3ltQMvWKJyxtfE5bNYLsY3WTW0kslf7XgTr5oOm1gZYiDrI+nmcm1bo8KjPc0Iofz+/UQ5ClvXPIpsJB6EqkokPGrXd+OxiDYOJ1IYr2IA8Yx6Q4="
    static let blobFrameHex = "5452534201000102030405060708090a0b2bc5cb528faba99aa8278c40f26949896b22f21ca966"
}
