import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// Concurrent edits of one thought through the engine: the 3-way merge, conflict copies, and resolving a copy.
@MainActor
@Suite("Sync conflicts")
struct SyncConflictTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func devices(_ count: Int = 2) async throws -> [SyncDevice] {
        var result: [SyncDevice] = []
        for index in 0..<count { result.append(try await SyncDevice("D\(index)", server: server)) }
        return result
    }

    func expectSame(_ devices: [SyncDevice], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = try devices[0].canonicalDump()
        for device in devices.dropFirst() {
            #expect(try device.canonicalDump() == reference, "\(device.name) differs", sourceLocation: sourceLocation)
        }
    }

    func copies(on device: SyncDevice) throws -> [Thought] {
        try device.context.fetch(FetchDescriptor<Thought>(predicate: ThoughtCounts.conflictCopies, sortBy: [SortDescriptor(\.id)]))
    }

    /// A thought both devices have, with the given body.
    func shared(_ body: String, blocks: [BlockDraft] = [], images: [ImageDraft] = [], on devices: [SyncDevice]) async throws -> UUID {
        let id = devices[0].store.create(body: body, blocks: blocks, images: images, now: devices[0].now(at(0))).id
        try await syncToQuiescence(devices, server: server)
        return id
    }

    func edit(_ device: SyncDevice, _ id: UUID, body: String, blocks: [BlockDraft]? = nil, at seconds: Double) throws {
        let thought = try #require(try device.thought(id))
        device.store.update(thought, body: body, blocks: blocks ?? RandomizedOperationTests.currentDrafts(of: thought), intervalDays: thought.intervalDays, now: device.now(at(seconds)))
    }

    // MARK: Clean merges

    @Test func editsToDifferentParagraphsMergeOnBothDevices() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo\nthree\nfour\nfive", on: all)
        try edit(a, id, body: "ONE\ntwo\nthree\nfour\nfive", at: 100)
        try edit(b, id, body: "one\ntwo\nthree\nfour\nFIVE", at: 200)
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try device.thought(id)?.body == "ONE\ntwo\nthree\nfour\nFIVE", "\(device.name)")
            #expect(try device.thoughts().count == 1, "no copy for a clean merge")
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func theDeviceThatLostThePushRaceMergesAndTheOtherOneReceivesTheResultAsAPlainChange() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo\nthree\nfour\nfive", on: all)
        try edit(a, id, body: "ONE\ntwo\nthree\nfour\nfive", at: 100)
        try edit(b, id, body: "one\ntwo\nthree\nfour\nFIVE", at: 200)
        await a.sync()
        let afterA = await server.headSeq
        await b.sync()
        #expect(await server.headSeq > afterA, "the merged result was pushed")
        let merged = try #require(try b.thought(id))
        #expect(merged.body == "ONE\ntwo\nthree\nfour\nFIVE")
        #expect(merged.updatedAt > at(200), "a new content clock")
        let before = try #require(try a.thought(id)).body
        await a.sync()
        #expect(before == "ONE\ntwo\nthree\nfour\nfive")
        #expect(try a.thought(id)?.body == merged.body)
        #expect(try await a.state.outboxCount() == 0, "A applied it without queueing anything")
        try expectSame(all)
    }

    @Test func blockEditsAndAdditionsMergeAcrossDevices() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("body\nline", blocks: [BlockDraft(content: "first\nblock"), BlockDraft(content: "second")], on: all)
        let draftsA = RandomizedOperationTests.currentDrafts(of: try #require(try a.thought(id)))
        var changedA = draftsA
        changedA[0].content = "FIRST\nblock"
        try edit(a, id, body: "body\nline", blocks: changedA, at: 100)
        var changedB = RandomizedOperationTests.currentDrafts(of: try #require(try b.thought(id)))
        changedB.append(BlockDraft(content: "third"))
        try edit(b, id, body: "body\nline", blocks: changedB, at: 200)
        try await syncToQuiescence(all, server: server)
        for device in all {
            let thought = try #require(try device.thought(id))
            #expect(thought.sortedBlocks.map(\.content) == ["FIRST\nblock", "second", "third"], "\(device.name)")
            #expect(try device.thoughts().count == 1)
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func imagesAddedOnBothSidesSurviveTheMerge() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("top\nmiddle\nbottom", on: all)
        let imageA = newImage(1), imageB = newImage(2)
        let thoughtA = try #require(try a.thought(id))
        a.store.update(thoughtA, body: "top\nmiddle\nbottom\n\(ImageToken.token(for: imageA.id))", blocks: [], images: [imageA], intervalDays: nil, now: a.now(at(100)))
        let thoughtB = try #require(try b.thought(id))
        b.store.update(thoughtB, body: "\(ImageToken.token(for: imageB.id))\ntop\nmiddle\nbottom", blocks: [], images: [imageB], intervalDays: nil, now: b.now(at(200)))
        try await syncToQuiescence(all, server: server)
        for device in all {
            let thought = try #require(try device.thought(id))
            #expect(Set(ImageToken.references(in: thought.body)) == [imageA.id, imageB.id], "\(device.name)")
            #expect(Set((thought.images ?? []).map(\.id)) == [imageA.id, imageB.id])
            try await device.expectClean()
        }
        try expectSame(all)
    }

    // MARK: Conflict copies

    @Test(arguments: [true, false])
    func editingTheSameLineMakesOneCopyOnEveryDevice(laterEditSyncsFirst: Bool) async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo\nthree", on: all)
        try edit(a, id, body: "one\nA two\nthree", at: laterEditSyncsFirst ? 200 : 100)
        try edit(b, id, body: "one\nB two\nthree", at: laterEditSyncsFirst ? 100 : 200)
        try await syncToQuiescence(all, server: server)
        let winner = laterEditSyncsFirst ? "one\nA two\nthree" : "one\nB two\nthree"
        let loser = laterEditSyncsFirst ? "one\nB two\nthree" : "one\nA two\nthree"
        for device in all {
            #expect(try device.thought(id)?.body == winner, "\(device.name)")
            let found = try copies(on: device)
            #expect(found.count == 1, "\(device.name) has \(found.count) copies")
            let copy = try #require(found.first)
            #expect(copy.body == loser)
            #expect(copy.conflictOfID == id)
            #expect(copy.id != id && !copy.isPinned && !copy.isArchived)
            #expect(copy.intervalDays == nil && copy.intervalMode == .fixed)
            #expect(try device.thoughts().count == 2)
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func aCreationWhosePushResponseWasLostStillMergesWithAnotherDevicesEdit() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = a.store.create(body: "one\ntwo\nthree\nfour", now: a.now(at(0))).id
        await server.dropNextPushResponse()
        await a.sync()
        try edit(a, id, body: "ONE\ntwo\nthree\nfour", at: 100)
        await b.sync()
        try edit(b, id, body: "one\ntwo\nthree\nFOUR", at: 200)
        await b.sync()
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try device.thought(id)?.body == "ONE\ntwo\nthree\nFOUR", "\(device.name)")
            #expect(try device.thoughts().count == 1, "\(device.name) no copy")
        }
        try expectSame(all)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func aCopyMadeBeforeAFailedReplacementIsStillPushed(skip: Int) async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo\nthree", on: all)
        try edit(a, id, body: "one\nA two\nthree", at: 100)
        try edit(b, id, body: "one\nB two\nthree", at: 200)
        await b.sync()
        a.skipSaves = skip
        a.failSaves = 1
        await a.sync()
        a.skipSaves = 0
        a.failSaves = 0
        try await syncToQuiescence(all, server: server)
        #expect(try a.thoughts().count == b.thoughts().count, "skip \(skip)")
        #expect(try a.thought(id)?.body == "one\nB two\nthree")
        #expect(try copies(on: b).map(\.body) == ["one\nA two\nthree"])
        try expectSame(all)
    }

    @Test(arguments: Array(0..<12))
    func aSaveFailingInALaterSubBatchDoesNotTurnAnEarlierMergeIntoACopy(skip: Int) async throws {
        var config = SyncEngine.Configuration()
        config.maxApplyBytes = 1
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, config: config)
        let all = [a, b]
        var ids: [UUID] = []
        for tag in 1...2 {
            let image = newImage(UInt8(tag))
            ids.append(a.store.create(body: "l0\nl1\nl2\nl3\nl4\n\(ImageToken.token(for: image.id))", images: [image], now: a.now(at(0))).id)
        }
        try await syncToQuiescence(all, server: server)
        for id in ids {
            let mine = try #require(try a.thought(id))
            let added = newImage(UInt8.random(in: 10...250))
            a.store.update(
                mine, body: mine.body.replacingOccurrences(of: "l2", with: "A l2") + "\n" + ImageToken.token(for: added.id),
                blocks: [], images: [added], intervalDays: nil, now: a.now(at(100))
            )
            let theirs = try #require(try b.thought(id))
            b.store.update(theirs, body: theirs.body.replacingOccurrences(of: "l1", with: "B l1"), blocks: [], intervalDays: nil, now: b.now(at(200)))
        }
        await a.sync()
        b.skipSaves = skip
        b.failSaves = 1
        await b.sync()
        b.skipSaves = 0
        b.failSaves = 0
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try copies(on: device).isEmpty, "skip \(skip) \(device.name)")
            for id in ids {
                let body = try #require(try device.thought(id)).body
                #expect(body.contains("A l2") && body.contains("B l1"), "skip \(skip) \(device.name)")
            }
        }
        try expectSame(all)
    }

    @Test func aThoughtDeletedElsewhereLeavesNoNotedAttemptHere() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = a.store.create(body: "doomed", now: a.now(at(0))).id
        await server.dropNextPushResponse()
        await a.sync()
        await b.sync()
        b.store.delete(try #require(try b.thought(id)), now: b.now(at(50)))
        await b.sync()
        await a.sync()
        #expect(try a.thought(id) == nil)
        #expect(try await a.state.attemptCount() == 0)
    }

    @Test func aThoughtDeletedBeforeItsFirstPushWasAcknowledgedLeavesNoNotedAttempt() async throws {
        let a = try await devices()[0]
        let id = a.store.create(body: "gone", now: a.now(at(0))).id
        await server.dropNextPushResponse()
        await a.sync()
        #expect(try await a.state.attemptCount() == 1)
        a.store.delete(try #require(try a.thought(id)), now: a.now(at(10)))
        await a.sync()
        #expect(try await a.state.attemptCount() == 0)
    }

    @Test func twoDevicesRestoredFromOneBackupThatBothEditOfflineMakeOneCopyAndLoseNothing() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = a.store.create(body: "one\ntwo\nthree", now: a.now(at(0))).id
        let twin = Thought(body: "one\ntwo\nthree", createdAt: a.now(at(0)), nextDueAt: a.now(at(86_400)))
        twin.id = id
        b.context.insert(twin)
        try b.context.save()
        try await b.reconcile()
        try edit(a, id, body: "one\nA two\nthree", at: 100)
        try edit(b, id, body: "one\nB two\nthree", at: 200)
        try await syncToQuiescence(all, server: server)
        for device in all {
            let found = try copies(on: device)
            #expect(found.count == 1, "\(device.name)")
            #expect(Set(try device.thoughts().map(\.body)) == ["one\nB two\nthree", "one\nA two\nthree"])
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func bothSidesEditingDifferentLinesMergesWithoutACopy() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo\nthree\nfour\nfive", on: all)
        try edit(b, id, body: "one\ntwo\nthree\nfour\nFIVE", at: 100)
        try edit(a, id, body: "ONE\ntwo\nthree\nfour\nfive", at: 200)
        await a.sync()
        let status = await b.sync()
        #expect(status.lastError == nil)
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try device.thought(id)?.body == "ONE\ntwo\nthree\nfour\nFIVE", "\(device.name)")
            #expect(try device.thoughts().count == 1)
        }
        try expectSame(all)
    }

    @Test func aRemovedBlockAgainstAnEditedOneMakesACopyWithItsBlocksAndTagsAndLinks() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let target = a.store.create(body: "target", now: a.now(at(0))).id
        let id = try await shared("body #shared", blocks: [BlockDraft(content: "keep #inblock"), BlockDraft(kind: .thoughtLink, linkedThoughtID: target)], on: all)
        try await syncToQuiescence(all, server: server)
        var removed = RandomizedOperationTests.currentDrafts(of: try #require(try a.thought(id)))
        removed.removeFirst()
        try edit(a, id, body: "body #shared", blocks: removed, at: 100)
        var edited = RandomizedOperationTests.currentDrafts(of: try #require(try b.thought(id)))
        edited[0].content = "keep #inblock edited #fresh"
        try edit(b, id, body: "body #shared", blocks: edited, at: 200)
        try await syncToQuiescence(all, server: server)
        for device in all {
            let copy = try #require(try copies(on: device).first)
            let original = try #require(try device.thought(id))
            #expect(original.sortedBlocks.map(\.content) == ["keep #inblock edited #fresh", ""], "\(device.name): the later edit stays")
            #expect(copy.sortedBlocks.map(\.kind) == [.thoughtLink])
            #expect(copy.sortedBlocks.first?.linkedThoughtID == target, "its outgoing link comes with it")
            #expect(Set(copy.sortedBlocks.map(\.id)).isDisjoint(with: Set(original.sortedBlocks.map(\.id))))
            #expect(copy.sortedTags.map(\.name) == ["shared"])
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func aCopyBringsItsImagesAndFilesWithNewIdsAndTheBytes() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let inline = newImage(5)
        let gallery = BlockDraft(kind: .gallery, images: [newImage(6), newImage(7)])
        let file = fileBlock(fakeFile(9, name: "doc.pdf"))
        let id = try await shared("text\n\(ImageToken.token(for: inline.id))\nend", blocks: [BlockDraft(content: "block"), gallery, file], images: [inline], on: all)
        try edit(a, id, body: "text\n\(ImageToken.token(for: inline.id))\nA end", at: 100)
        try edit(b, id, body: "text\n\(ImageToken.token(for: inline.id))\nB end", at: 200)
        try await syncToQuiescence(all, server: server)
        for device in all {
            let original = try #require(try device.thought(id))
            let copy = try #require(try copies(on: device).first)
            #expect(copy.body.hasSuffix("A end"))
            let originalImages = Set((original.images ?? []).map(\.id))
            let copyImages = Set((copy.images ?? []).map(\.id))
            #expect(copyImages.count == 3 && copyImages.isDisjoint(with: originalImages))
            #expect(ImageToken.references(in: copy.body).allSatisfy { copyImages.contains($0) }, "tokens point at the copy's own images")
            #expect(!copy.body.contains(ImageToken.token(for: inline.id)))
            let originalBytes = Set((original.images ?? []).compactMap(\.data))
            #expect(Set((copy.images ?? []).compactMap(\.data)) == originalBytes)
            #expect((copy.files ?? []).count == 1 && (copy.files ?? []).first?.data == (original.files ?? []).first?.data)
            #expect(Set((copy.files ?? []).map(\.id)).isDisjoint(with: Set((original.files ?? []).map(\.id))))
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func twoDevicesMakingTheSameCopyEndUpWithOne() async throws {
        let all = try await devices(3)
        let (a, b, c) = (all[0], all[1], all[2])
        let id = try await shared("one\ntwo\nthree", on: all)
        try edit(c, id, body: "one\nC two\nthree", at: 50)
        await c.sync()
        try edit(a, id, body: "one\nA two\nthree", at: 100)
        try edit(b, id, body: "one\nB two\nthree", at: 200)
        // B runs its whole sync (and so makes the copy of C's version) while A is between pulling and pushing.
        let hookDevice = b
        await server.beforeNextPush { await hookDevice.sync() }
        await a.sync()
        try await syncToQuiescence(all, server: server)

        for device in all {
            let found = try copies(on: device)
            let ofC = found.filter { $0.body == "one\nC two\nthree" }
            #expect(ofC.count == 1, "\(device.name): C's version is in exactly one copy")
            #expect(found.count == Set(found.map(\.id)).count)
            #expect(try device.thought(id)?.body == "one\nB two\nthree")
            #expect(Set(found.map(\.body)) == ["one\nC two\nthree", "one\nA two\nthree"], "\(device.name) \(found.map(\.body))")
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func aDeletedCopyIsNotMadeAgain() async throws {
        let all = try await devices()
        let (a, b) = (all[0], all[1])
        let id = try await shared("one\ntwo", on: all)
        try edit(a, id, body: "one\nA", at: 100)
        try edit(b, id, body: "one\nB", at: 200)
        try await syncToQuiescence(all, server: server)
        let copy = try #require(try copies(on: b).first)
        b.store.keepOriginal(copy, now: b.now(at(300)))
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try copies(on: device).isEmpty, "\(device.name)")
            #expect(try device.thoughts().count == 1)
        }
        try expectSame(all)
    }

    // MARK: Resolving

    func conflicted(_ all: [SyncDevice]) async throws -> (id: UUID, copy: UUID) {
        let id = try await shared("one\ntwo\nthree", blocks: [BlockDraft(content: "block")], on: all)
        try edit(all[0], id, body: "one\nA two\nthree", at: 100)
        try edit(all[1], id, body: "one\nB two\nthree", at: 200)
        try await syncToQuiescence(all, server: server)
        return (id, try #require(try copies(on: all[0]).first).id)
    }

    @Test func keepBothClearsTheMarkOnEveryDevice() async throws {
        let all = try await devices()
        let (id, copyID) = try await conflicted(all)
        let copy = try #require(try all[0].thought(copyID))
        let before = copy.stateChangedAt
        #expect(all[0].store.keepBoth(copy, now: all[0].now(at(300))))
        #expect(copy.conflictOfID == nil && copy.stateChangedAt > before)
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try copies(on: device).isEmpty)
            #expect(try device.thought(copyID)?.body == "one\nA two\nthree")
            #expect(try device.thought(id) != nil)
        }
        try expectSame(all)
    }

    @Test func keepOriginalDeletesTheCopyEverywhere() async throws {
        let all = try await devices()
        let (id, copyID) = try await conflicted(all)
        let copy = try #require(try all[1].thought(copyID))
        #expect(all[1].store.keepOriginal(copy, now: all[1].now(at(300))))
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try device.thought(copyID) == nil)
            #expect(try device.thought(id)?.body == "one\nB two\nthree")
            #expect(try device.thoughts().count == 1)
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func keepCopyReplacesTheOriginalsContentAndDeletesTheCopy() async throws {
        let all = try await devices()
        let (id, copyID) = try await conflicted(all)
        let copy = try #require(try all[0].thought(copyID))
        let original = try #require(try all[0].thought(id))
        let schedule = original.nextDueAt
        #expect(all[0].store.keepCopy(copy, now: all[0].now(at(300))))
        #expect(original.body == "one\nA two\nthree")
        #expect(original.scheduleChangedAt < all[0].now(at(300)), "only the content group moved")
        #expect(original.nextDueAt == schedule)
        try await syncToQuiescence(all, server: server)
        for device in all {
            #expect(try device.thought(copyID) == nil)
            #expect(try device.thought(id)?.body == "one\nA two\nthree")
            #expect(try device.thought(id)?.sortedBlocks.map(\.content) == ["block"])
            #expect(try device.thoughts().count == 1)
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func keepCopyBringsTheCopysImagesAcross() async throws {
        let all = try await devices()
        let inline = newImage(3)
        let id = try await shared("a\n\(ImageToken.token(for: inline.id))\nb", blocks: [BlockDraft(kind: .gallery, images: [newImage(4)])], images: [inline], on: all)
        try edit(all[0], id, body: "a\n\(ImageToken.token(for: inline.id))\nA b", at: 100)
        try edit(all[1], id, body: "a\n\(ImageToken.token(for: inline.id))\nB b", at: 200)
        try await syncToQuiescence(all, server: server)
        let copy = try #require(try copies(on: all[1]).first)
        let copyBytes = Set((copy.images ?? []).compactMap(\.data))
        #expect(all[1].store.keepCopy(copy, now: all[1].now(at(300))))
        try await syncToQuiescence(all, server: server)
        for device in all {
            let original = try #require(try device.thought(id))
            #expect(original.body.hasSuffix("A b"))
            #expect(Set((original.images ?? []).compactMap(\.data)) == copyBytes)
            #expect(ImageToken.references(in: original.body).allSatisfy { token in (original.images ?? []).contains { $0.id == token } })
            #expect(try device.thoughts().count == 1)
            try await device.expectClean()
        }
        try expectSame(all)
    }

    @Test func whenTheOriginalIsGoneKeepBothAndDeleteWorkButKeepCopyIsNotOffered() async throws {
        let all = try await devices()
        let a = all[0]
        let (id, copyID) = try await conflicted(all)
        let original = try #require(try a.thought(id))
        a.store.delete(original, now: a.now(at(300)))
        let copy = try #require(try a.thought(copyID))
        #expect(!a.store.keepCopy(copy, now: a.now(at(310))), "nothing to replace")
        #expect(copy.conflictOfID == id)
        #expect(try a.thought(copyID) != nil)
        #expect(a.store.keepBoth(copy, now: a.now(at(320))))
        #expect(copy.conflictOfID == nil)
        try await syncToQuiescence(all, server: server)
        try expectSame(all)
        #expect(try all[1].thought(copyID)?.conflictOfID == nil)
    }

    @Test func deleteStillWorksOnADanglingCopy() async throws {
        let all = try await devices()
        let (id, copyID) = try await conflicted(all)
        all[0].store.delete(try #require(try all[0].thought(id)), now: all[0].now(at(400)))
        let dangling = try #require(try all[0].thought(copyID))
        #expect(all[0].store.keepOriginal(dangling, now: all[0].now(at(410))))
        #expect(try all[0].thought(copyID) == nil)
        try await all[0].expectClean()
    }

    @Test func aFailedSaveLeavesTheCopyAndOriginalAsTheyWere() async throws {
        let all = try await devices()
        let (id, copyID) = try await conflicted(all)
        let a = all[0]
        let copy = try #require(try a.thought(copyID))
        a.failSaves = 1
        #expect(!a.store.keepCopy(copy, now: a.now(at(300))))
        #expect(try a.thought(copyID) != nil)
        #expect(try a.thought(id)?.body == "one\nB two\nthree")
        try await a.expectClean()
        #expect(a.store.keepCopy(try #require(try a.thought(copyID)), now: a.now(at(310))), "trying again finishes it")
        try await a.expectClean()
    }

    // MARK: Counting

    @Test func conflictCopiesAreCountedAndPagedByPredicate() async throws {
        let all = try await devices()
        _ = try await conflicted(all)
        let result = ThoughtCounts.conflictCopies(limit: 10, in: all[0].context)
        #expect(result.total == 1 && result.thoughts.count == 1)
        #expect(ThoughtCounts.count(ThoughtCounts.conflictCopies, in: all[0].context, limit: 1) == 1)
    }
}
