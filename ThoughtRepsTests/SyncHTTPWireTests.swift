import CryptoKit
import Foundation
import Testing
@testable import ThoughtReps

private final class WireBundleToken {}

/// The golden fixtures mirror `thoughtreps-aws` `infra/lambda/sync/fixtures/wire-v1/` byte for byte; the hashes are the
/// ones `wire-v1.test.ts` pins there. A change to a fixture changes both repos.
@Suite("Sync HTTP wire v1")
struct SyncHTTPWireTests {
    static let hashes: [String: String] = [
        "push-request": "099aff624fc629ebf5e28c226c6433c6ed27d938a241e814f3f93d88e32af66e",
        "push-ok": "eec6dcb52290a8c514802e33fde2794f98af6363b24a8eea3eef5bcdbfab62f2",
        "push-conflict": "1bd4b16336ac4033bc7e153df455179e35eddca7b3a34516a762c8264f0af2bb",
        "push-epoch-changed": "a9fc8185d1791347ce6169cfba4886eedcebd8600bd81010f8fb64ebf2016a56",
        "pull-page-more": "ead5245082402b57d778e9a9129e4b930cae60b7b3041afe4e172d267556228f",
        "pull-page-last": "7e48ce73c26f879234162a7bd203fbfb74ca1182659301dcd189ab8b696b0a49",
        "head": "aa452e7164e0958c1769837c22a9ae58b51f20434ae5ed129021d720c992e95d",
        "error-too-large": "7a52e6f92cce730e6a487738600fe3d785806351e8eed45683ebc92b6fc5fa72",
        "error-busy": "36e34e3971d8c342d573a99f07fd4f21fedf7792ebfbc859e93e58b10a237546",
        "error-unauthorized": "3e191a8e87092c34cb1e684ccfc87baaa5f7406f72030355ae0fba347d8deb41",
        "dev-create-vault": "af9876009c1900091aabef5efb03b618fc33be4418b501ff4912f74e842f2ec8",
        "dev-erase-vault": "022ca820a818a48eeb6528cbd2c92e97798008ccfeccb1bcf429e0addefb7042",
    ]
    static let serverTime: Int64 = 1_768_478_400_000
    static let keyA = "Q-Y85gZYeFMCw5FLlo5pPem-fdXn9BQl7fi8MEJti1Q"
    static let keyB = "cEqYZBq5_keBcdVD0vHgqpHZEhaFzkzXXaEcZU7T4eY"

    func bytes(_ name: String) throws -> Data {
        let folder = try #require(Bundle(for: WireBundleToken.self).url(forResource: "SyncWireV1", withExtension: nil))
        return try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
    }

    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: bytes(name))
    }

    @Test(arguments: hashes.keys.sorted()) func eachFixtureIsByteStable(name: String) throws {
        let digest = SHA256.hash(data: try bytes(name)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.hashes[name])
    }

    @Test func theFolderHoldsExactlyTheListedFixtures() throws {
        let folder = try #require(Bundle(for: WireBundleToken.self).url(forResource: "SyncWireV1", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        #expect(names == Self.hashes.keys.sorted())
    }

    @Test func thePushRequestDecodesAndReEncodesToTheSameObject() throws {
        let request = try decode(SyncHTTPWireV1.PushRequest.self, "push-request")
        #expect(request.epoch == 1)
        #expect(request.records.map(\.key) == [Self.keyA, Self.keyB])
        #expect(request.records.map(\.baseSeq) == [nil, 4])
        #expect(request.records.map(\.deleted) == [false, true])
        #expect(request.records[0].payload == Data("TR01 sealed payload for record a".utf8))
        #expect(request.records[1].payload.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: bytes("push-request")) as? NSDictionary
        #expect(encoded != nil && encoded == fixture)
    }

    @Test func pushResponses() throws {
        let ok = try decode(SyncHTTPWireV1.PushOK.self, "push-ok")
        #expect(ok == SyncHTTPWireV1.PushOK(headSeq: 6, seqs: [Self.keyA: 5, Self.keyB: 6], serverTime: Self.serverTime))
        let conflict = try decode(SyncHTTPWireV1.ErrorBody.self, "push-conflict")
        #expect(conflict.error == "conflict" && conflict.conflicts == [Self.keyB] && conflict.epochChanged == nil)
        let epoch = try decode(SyncHTTPWireV1.ErrorBody.self, "push-epoch-changed")
        #expect(epoch.error == "epoch_changed" && epoch.epochChanged == true && epoch.epoch == 2 && epoch.conflicts == nil)
    }

    @Test func pullPages() throws {
        let more = try decode(SyncHTTPWireV1.PullPage.self, "pull-page-more")
        #expect(more.records.map(\.seq) == [5, 6] && more.records.map(\.deleted) == [false, true])
        #expect(more.records[0].payload == Data("TR01 sealed payload for record a".utf8) && more.records[1].payload.isEmpty)
        #expect(more.nextSeq == 6 && more.headSeq == 9 && more.more && more.epoch == 1 && more.serverTime == Self.serverTime)
        let last = try decode(SyncHTTPWireV1.PullPage.self, "pull-page-last")
        #expect(last.records.map(\.key) == ["66hvlInjnHpfc8lBlN-Ow3vKAVWFTbl2hxX-e8WCX9k"] && last.records[0].seq == 9)
        #expect(last.records[0].payload == Data("TR01 sealed payload for record b".utf8))
        #expect(last.nextSeq == 9 && last.headSeq == 9 && !last.more)
    }

    @Test func headAndErrors() throws {
        #expect(try decode(SyncHTTPWireV1.Head.self, "head") == SyncHTTPWireV1.Head(headSeq: 9, epoch: 1, liveRecordCount: 2, serverTime: Self.serverTime))
        for (name, code) in [("error-too-large", "too_large"), ("error-busy", "busy"), ("error-unauthorized", "unauthorized")] {
            let body = try decode(SyncHTTPWireV1.ErrorBody.self, name)
            #expect(body.error == code && body.message?.isEmpty == false && body.serverTime == Self.serverTime, "\(name)")
        }
    }

    @Test func devRoutes() throws {
        #expect(try decode(SyncHTTPWireV1.CreateVault.self, "dev-create-vault") == SyncHTTPWireV1.CreateVault(vaultId: "wire-v1-vault", epoch: 1, created: true, serverTime: Self.serverTime))
        #expect(try decode(SyncHTTPWireV1.EraseVault.self, "dev-erase-vault") == SyncHTTPWireV1.EraseVault(epoch: 2, serverTime: Self.serverTime))
    }

    @Test func everyResponseFixtureCarriesTheServerTime() throws {
        for name in Self.hashes.keys where name != "push-request" {
            #expect(try decode(SyncHTTPWireV1.TimeOnly.self, name).serverTime == Self.serverTime, "\(name)")
        }
    }
}
