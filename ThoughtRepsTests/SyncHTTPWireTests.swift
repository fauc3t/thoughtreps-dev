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
        "blob-upload-urls-request": "592430bc961209c0d4e5b2012e09fef17ce0255d9172a4cbc2b397bdcb6e6d30",
        "blob-upload-urls-response": "8b2b49114a584c448d053fe759f37f333f587e22a9cd4808cf847a93a941e41e",
        "blob-download-urls-request": "fce9161d08a359c90f9cf467eba938016db75706a67512a499b3eb493495e73e",
        "blob-download-urls-response": "1d4b7e1efeb476d51db2c2dca56657ccb1157a4f429c1c2a9491acc382f3c1d7",
        "push-pointer-request": "6f924da9f8e67955f5aa1b48ab8005ca41ca7251ec883a900abda4afdb9915f3",
        "push-pointer-missing-blob": "1df8fae7a2c5aecc069d72d87fd7e43e7cdf4e3efd96210e57380510bef7a32b",
        "garbage-collection-live-list-url-request": "f8f222c7cee3115ccf01a6280e557389b9ebfe9a82824c4c6a476515cbef96d3",
        "garbage-collection-live-list-url-response": "5bcfa1048f17d820c830e3776c8ad8ed4de3c2bbeb121933f98b8142104a80f3",
        "garbage-collection-start-request": "782b66f422aced1754c16d5f2c69bbb16e855b5d6101e4019ee084c303dfe2e9",
        "garbage-collection-start-response": "e1663a68c6bda366377e2ea561aa4775a3773b4c2d4070ae91ffda242ad1c82a",
        "garbage-collection-stale": "d9a72a703b6298b4b6a8f03def0bc40bbe1086bc73e47d45255c425bf0a48262",
        "garbage-collection-live-list-missing": "7a50fd11a3fa32bc7954e2b9f3bf6fdd49127a418a7a92a2364024f53e0f2cbd",
        "garbage-collection-rate-limited": "41c7ca52b2e262425ceb60d8f09ea1153828ee102a8e66f73315a78e4c9fe09d",
        "blob-quota-exceeded": "238738de2e9f00f8b45c4dafc2d2a615d55bc81d5db3e8502a1a76d0e9e3532c",
        "dev-create-vault": "af9876009c1900091aabef5efb03b618fc33be4418b501ff4912f74e842f2ec8",
        "dev-erase-vault": "022ca820a818a48eeb6528cbd2c92e97798008ccfeccb1bcf429e0addefb7042",
        "device-challenge-response": "a998af43aa01e3836805a0e850879dde6d8857b57b397f875dfbedb04cb8a305",
        "device-register-request": "f7cf3e4fba912b528a0a937f5a0ea73e75d51205aa97a43ee0b2430e7cf855df",
        "device-register-response": "3e462330d0712c7da84fb1f8288522bf4dee31bcefaa24db53bfe32e395cb108",
        "sign-in-with-apple-request": "5bd20c000bcdc9c3cd5e8eb123edca652b9a064df24692f75e82fb207644c07c",
        "sign-in-with-apple-response": "b2326b78943e395903104b798c2511baa7d4c49d84a03a4a54e19e97f79cd1d4",
        "session-request": "2ddd58f8ff4977abba6017592ea3d1d36d3c1897805247243d4aa799a78260c1",
        "session-response": "bcdeb51b4aba4f77771f627017df08c87746f476fd4ae2feed0f036a437b9dd9",
        "vault-create-request": "bdc5bd55bbca88a6e9a8aac78378471182c3de11bf6dc2b31bcd6ef1a7524cd7",
        "vault-create-response": "e52f47f8c87207b83a99c6df9155357bc00a399c77261cc28f7ff14b9d24467e",
        "error-vault-exists": "348b02f76a2df97a0fc947c789c634a1d112275a3d6cab7ad9579e28a7ddf7f2",
        "error-assertion-invalid": "c175c208cf9b013bbc5adca9138d6247746b54267e063d5e153cac937298ddb7",
        "error-challenge-invalid": "236915cb84c223ad254a1e027081781b23bb8545ff4cc0612e9ea42588907fd6",
        "error-attestation-invalid": "de3c02ec4626557f1d04e47de060a587b6887fc01ce1d4627982dff28cf6d031",
        "error-identity-token-invalid": "d44139cce761ae57fd37c7632beb6a18ab658b0ebaa02273175d32094f1c9984",
        "error-forbidden": "bb94e9beb6d32c2d3c0c62b305aa1c38ba88f74366047e993782d9ce1a0e4ca1",
        "error-device-in-vault": "5ad9e4a97f43fb787125baaf2f1c28506b49a736fc33742a88daa2a6db686ea4",
    ]
    static let requestFixtures: Set<String> = [
        "push-request", "push-pointer-request", "blob-upload-urls-request", "blob-download-urls-request",
        "garbage-collection-live-list-url-request", "garbage-collection-start-request",
        "device-register-request", "sign-in-with-apple-request", "session-request", "vault-create-request",
    ]
    static let runID = "0123456789abcdef0123456789abcdef"
    static let serverTime: Int64 = 1_768_478_400_000
    static let blobA = "ERERERERERERERERERERERERERERERERERERERERERE"
    static let blobB = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"
    static let blobC = "MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM"
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
        for name in Self.hashes.keys where !Self.requestFixtures.contains(name) {
            #expect(try decode(SyncHTTPWireV1.TimeOnly.self, name).serverTime == Self.serverTime, "\(name)")
        }
    }

    func expectReEncodesToTheFixture<T: Codable>(_ value: T, _ name: String) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: bytes(name)) as? NSDictionary
        #expect(encoded != nil && encoded == fixture, "\(name)")
    }

    @Test func blobUploadURLs() throws {
        let request = try decode(SyncHTTPWireV1.BlobUploadURLsRequest.self, "blob-upload-urls-request")
        #expect(request.epoch == 1)
        #expect(request.blobs.map(\.name) == [Self.blobA, Self.blobB] && request.blobs.map(\.size) == [184_233, 9_120])
        #expect(request.blobs[0].sha256 == "ypeBEsobvcr6wjGzmiPcTaeG7/gUfE5yuYB3ha/uSLs=" && request.blobs.allSatisfy { $0.sha256.count == 44 })
        try expectReEncodesToTheFixture(request, "blob-upload-urls-request")

        let response = try decode(SyncHTTPWireV1.BlobUploadURLsResponse.self, "blob-upload-urls-response")
        #expect(response.uploads.map(\.name) == [Self.blobA] && response.present == [Self.blobB] && response.serverTime == Self.serverTime)
        #expect(response.uploads[0].headers == ["x-amz-checksum-sha256": "ypeBEsobvcr6wjGzmiPcTaeG7/gUfE5yuYB3ha/uSLs="])
        #expect(response.uploads[0].url.hasPrefix("https://") && response.uploads[0].url.contains("X-Amz-Signature="))
    }

    @Test func blobDownloadURLs() throws {
        let request = try decode(SyncHTTPWireV1.BlobDownloadURLsRequest.self, "blob-download-urls-request")
        #expect(request == SyncHTTPWireV1.BlobDownloadURLsRequest(epoch: 1, names: [Self.blobA, Self.blobB, Self.blobC]))
        try expectReEncodesToTheFixture(request, "blob-download-urls-request")

        let response = try decode(SyncHTTPWireV1.BlobDownloadURLsResponse.self, "blob-download-urls-response")
        #expect(response.downloads.map(\.name) == [Self.blobA, Self.blobB] && response.downloads.map(\.size) == [184_233, 9_120])
        #expect(response.missing == [Self.blobC] && response.serverTime == Self.serverTime)
        #expect(response.downloads.allSatisfy { $0.url.hasPrefix("https://") })
    }

    @Test func aPointerPushAndItsMissingBlobAnswer() throws {
        let request = try decode(SyncHTTPWireV1.PushRequest.self, "push-pointer-request")
        #expect(request.epoch == 1 && request.records.map(\.key) == ["rec-big"] && request.records[0].baseSeq == nil)
        #expect(SyncCrypto.blobName(inPointer: request.records[0].payload) == Self.blobA)
        try expectReEncodesToTheFixture(request, "push-pointer-request")

        let missing = try decode(SyncHTTPWireV1.ErrorBody.self, "push-pointer-missing-blob")
        #expect(missing.error == "blob_missing" && missing.missingBlobs == [Self.blobC] && missing.conflicts == nil && missing.epochChanged == nil)
    }

    @Test func garbageCollectionRequestsAndResponses() throws {
        let listURL = try decode(SyncHTTPWireV1.LiveListURLRequest.self, "garbage-collection-live-list-url-request")
        #expect(listURL == SyncHTTPWireV1.LiveListURLRequest(epoch: 1, size: 88, sha256: "eM8Q83Na+fcfFU85+p70pzU33vxFqx9t5EpWcrBTr60="))
        #expect(listURL.size % 44 == 0 && listURL.sha256.count == 44)
        try expectReEncodesToTheFixture(listURL, "garbage-collection-live-list-url-request")

        let target = try decode(SyncHTTPWireV1.LiveListURLResponse.self, "garbage-collection-live-list-url-response")
        #expect(target.runId == Self.runID && target.serverTime == Self.serverTime)
        #expect(target.headers == ["x-amz-checksum-sha256": listURL.sha256])
        #expect(target.url.hasPrefix("https://") && target.url.contains("X-Amz-Signature="))
        try expectReEncodesToTheFixture(target, "garbage-collection-live-list-url-response")

        let start = try decode(SyncHTTPWireV1.StartGarbageCollectionRequest.self, "garbage-collection-start-request")
        #expect(start == SyncHTTPWireV1.StartGarbageCollectionRequest(epoch: 1, runId: Self.runID, asOfSeq: 42))
        try expectReEncodesToTheFixture(start, "garbage-collection-start-request")

        let started = try decode(SyncHTTPWireV1.StartGarbageCollectionResponse.self, "garbage-collection-start-response")
        #expect(started == SyncHTTPWireV1.StartGarbageCollectionResponse(runId: Self.runID, serverTime: Self.serverTime))
        try expectReEncodesToTheFixture(started, "garbage-collection-start-response")
    }

    @Test func garbageCollectionAndQuotaRefusals() throws {
        let stale = try decode(SyncHTTPWireV1.GarbageCollectionStale.self, "garbage-collection-stale")
        #expect(stale == SyncHTTPWireV1.GarbageCollectionStale(error: "garbage_collection_stale", headSeq: 43, serverTime: Self.serverTime))
        try expectReEncodesToTheFixture(stale, "garbage-collection-stale")

        let missing = try decode(SyncHTTPWireV1.LiveListMissing.self, "garbage-collection-live-list-missing")
        #expect(missing == SyncHTTPWireV1.LiveListMissing(error: "live_list_missing", serverTime: Self.serverTime))
        try expectReEncodesToTheFixture(missing, "garbage-collection-live-list-missing")

        let limited = try decode(SyncHTTPWireV1.GarbageCollectionRateLimited.self, "garbage-collection-rate-limited")
        #expect(limited == SyncHTTPWireV1.GarbageCollectionRateLimited(error: "garbage_collection_rate_limited", retryAfterSeconds: 2400, serverTime: Self.serverTime))
        try expectReEncodesToTheFixture(limited, "garbage-collection-rate-limited")

        let quota = try decode(SyncHTTPWireV1.QuotaExceeded.self, "blob-quota-exceeded")
        #expect(quota == SyncHTTPWireV1.QuotaExceeded(error: "quota_exceeded", usedBytes: 10_737_000_000, limitBytes: 10_737_418_240, serverTime: Self.serverTime))
        try expectReEncodesToTheFixture(quota, "blob-quota-exceeded")

        for name in ["garbage-collection-stale", "garbage-collection-live-list-missing", "garbage-collection-rate-limited", "blob-quota-exceeded"] {
            #expect(try decode(SyncHTTPWireV1.ErrorBody.self, name).error != nil, "the transport reads the code through ErrorBody: \(name)")
        }
    }

    static let challenge = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdE"
    static let userID = "Zk3x9QvT2mLpR8sWnD4aYg"
    static let accountVaultID = "k7P2mQx9LwT4vB8nRcZ1sA"

    @Test func deviceRegistration() throws {
        let challenge = try decode(SyncHTTPWireV1.DeviceChallenge.self, "device-challenge-response")
        #expect(challenge == SyncHTTPWireV1.DeviceChallenge(challenge: Self.challenge, expiresAt: 1_768_478_700_000, serverTime: Self.serverTime))
        let request = try decode(SyncHTTPWireV1.DeviceRegisterRequest.self, "device-register-request")
        #expect(request == SyncHTTPWireV1.DeviceRegisterRequest(
            keyId: "pN3GFqlKsfvBzng1wDPNFHcV9Cf4xaxgPjrULMK7Jmk=", attestation: "AAECAwQFBgcICQoLDA0ODw==", challenge: Self.challenge
        ))
        try expectReEncodesToTheFixture(request, "device-register-request")
        #expect(try decode(SyncHTTPWireV1.DeviceRegisterResponse.self, "device-register-response") == SyncHTTPWireV1.DeviceRegisterResponse(registered: true, serverTime: Self.serverTime))
    }

    @Test func signInAndSessions() throws {
        let signIn = try decode(SyncHTTPWireV1.SignInWithAppleRequest.self, "sign-in-with-apple-request")
        #expect(signIn.challenge == Self.challenge && signIn.identityToken.hasPrefix("eyJ"))
        try expectReEncodesToTheFixture(signIn, "sign-in-with-apple-request")
        let session = try decode(SyncHTTPWireV1.SessionRequest.self, "session-request")
        #expect(session == SyncHTTPWireV1.SessionRequest(challenge: Self.challenge))
        try expectReEncodesToTheFixture(session, "session-request")

        let vaultless = try decode(SyncHTTPWireV1.AccountSession.self, "sign-in-with-apple-response")
        #expect(vaultless.userId == Self.userID && vaultless.vaultId == nil)
        #expect(vaultless.session.expiresAt == 1_768_482_000_000 && vaultless.session.token.hasPrefix("v1.") && vaultless.serverTime == Self.serverTime)
        let withVault = try decode(SyncHTTPWireV1.AccountSession.self, "session-response")
        #expect(withVault.userId == Self.userID && withVault.vaultId == Self.accountVaultID)
        #expect(withVault.session.expiresAt == 1_768_482_000_000 && withVault.serverTime == Self.serverTime)
    }

    @Test func vaultCreation() throws {
        let request = try decode(SyncHTTPWireV1.CreateAccountVaultRequest.self, "vault-create-request")
        #expect(request.kAuthVerifier == "GMVd8zyX+0ku7I1tZ/45wG8lcb1uUKMVm215Vjd8hUY=")
        try expectReEncodesToTheFixture(request, "vault-create-request")
        let response = try decode(SyncHTTPWireV1.CreateAccountVaultResponse.self, "vault-create-response")
        #expect(response.vaultId == Self.accountVaultID && response.epoch == 1 && response.serverTime == Self.serverTime)
        #expect(response.session == (try decode(SyncHTTPWireV1.AccountSession.self, "session-response")).session)
    }

    @Test func accountErrorsMapToTheirCodes() throws {
        let cases: [(String, SyncAccountError.Code)] = [
            ("error-vault-exists", .vaultExists), ("error-assertion-invalid", .assertionInvalid),
            ("error-challenge-invalid", .challengeInvalid), ("error-attestation-invalid", .attestationInvalid),
            ("error-identity-token-invalid", .identityTokenInvalid), ("error-forbidden", .forbidden),
            ("error-device-in-vault", .deviceInVault),
        ]
        for (name, code) in cases {
            let body = try decode(SyncHTTPWireV1.ErrorBody.self, name)
            #expect(body.error == code.rawValue && body.message?.isEmpty == false, "\(name)")
            #expect(SyncAccountError.from(status: 409, body: try bytes(name)).code == code, "\(name)")
        }
    }
}
