import Foundation
import Testing
@testable import ThoughtReps

struct CaptureContextTests {
    private let swift = ThoughtReps.Tag(name: "swift", displayName: "swift")
    private let ink = ThoughtReps.Tag(name: "ink", displayName: "ink")

    @Test func registerThenUnregister() {
        let context = CaptureContext()
        let token = UUID()
        #expect(context.tag == nil)
        context.register(token: token, tag: swift)
        #expect(context.tag === swift)
        context.unregister(token: token)
        #expect(context.tag == nil)
    }

    @Test func strayInstanceDisappearingKeepsRealTag() {
        let context = CaptureContext()
        let stray = UUID(), real = UUID()
        context.register(token: stray, tag: swift)
        context.register(token: real, tag: swift)
        context.unregister(token: stray)
        #expect(context.tag === swift)
    }

    @Test func olderTokenUnregisteringLeavesNewer() {
        let context = CaptureContext()
        let older = UUID(), newer = UUID()
        context.register(token: older, tag: swift)
        context.register(token: newer, tag: ink)
        context.unregister(token: older)
        #expect(context.tag === ink)
    }

    @Test func mostRecentRegistrationWins() {
        let context = CaptureContext()
        let first = UUID(), second = UUID()
        context.register(token: first, tag: swift)
        context.register(token: second, tag: ink)
        #expect(context.tag === ink)
        context.register(token: first, tag: swift)
        #expect(context.tag === swift)
        context.unregister(token: first)
        #expect(context.tag === ink)
    }

    @Test func unregisteringUnknownTokenIsNoOp() {
        let context = CaptureContext()
        context.register(token: UUID(), tag: swift)
        context.unregister(token: UUID())
        #expect(context.tag === swift)
    }

    @Test func reRegisteringSameTokenReplacesEntry() {
        let context = CaptureContext()
        let token = UUID()
        context.register(token: token, tag: swift)
        context.register(token: token, tag: ink)
        #expect(context.tag === ink)
        context.unregister(token: token)
        #expect(context.tag == nil)
    }
}
