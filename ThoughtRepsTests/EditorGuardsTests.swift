import Foundation
import Testing
import SwiftData
import SwiftUI
import UIKit
@testable import ThoughtReps

@MainActor
@Suite("Editor and navigation guards", .serialized)
struct EditorGuardsTests {
    private func window() -> (UIWindow, UIViewController) {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = root
        window.makeKeyAndVisible()
        return (window, root)
    }

    private func present(_ controller: UIViewController, over presenter: UIViewController) {
        presenter.present(controller, animated: false)
    }

    private var hostRoot: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.rootViewController
    }

    @Test func dropWithNoProvidersStartsNoLoad() {
        let intake = ImageIntake()
        #expect(!intake.ingestDropped([]))
        #expect(!intake.isProcessing)
    }

    @Test func dropOfABareURLIsRejectedAndNeverFetched() {
        let intake = ImageIntake()
        let provider = NSItemProvider(object: URL(string: "https://example.com/a.png")! as NSURL)
        #expect(!intake.ingestDropped([provider]))
        #expect(!intake.isProcessing)
        #expect(!intake.failed)
    }

    @Test func dropOfAnImageIsAccepted() {
        let intake = ImageIntake()
        let provider = NSItemProvider(item: Data() as NSData, typeIdentifier: "public.png")
        #expect(intake.ingestDropped([provider]))
        #expect(intake.isProcessing)
    }

    @Test func modalPresenceCountsSheetsFromTheRoot() async throws {
        let (window, root) = window()
        defer { window.isHidden = true }
        #expect(!ModalPresence.isPresenting(from: root))
        #expect(!ModalPresence.isPresentingOverFirstSheet(from: root))
        let sheet = UIViewController()
        present(sheet, over: root)
        #expect(ModalPresence.isPresenting(from: root))
        #expect(!ModalPresence.isPresentingOverFirstSheet(from: root))
        try await Task.sleep(for: .milliseconds(100))
        present(UIViewController(), over: sheet)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ModalPresence.isPresentingOverFirstSheet(from: root))
    }

    @Test func modalPresenceIsFalseWithoutAWindow() {
        #expect(!ModalPresence.isPresenting(from: nil))
        #expect(!ModalPresence.isPresentingOverFirstSheet(from: nil))
    }

    @Test func requestsActWhenNothingIsPresented() throws {
        try #require(hostRoot?.presentedViewController == nil)
        let navigation = AppNavigation()
        navigation.requestNewThought()
        #expect(navigation.newThoughtRequestCount == 1)
        navigation.requestTab(.stats)
        #expect(navigation.selectedTab == .stats)
        navigation.requestSearch()
        #expect(navigation.selectedTab == .timeline)
        #expect(navigation.searchRequestCount == 1)
        navigation.requestSettings()
        #expect(navigation.showSettings)
    }

    @Test func requestsStandDownWhileASheetIsUp() async throws {
        let root = try #require(hostRoot)
        present(UIViewController(), over: root)
        try await Task.sleep(for: .milliseconds(100))
        try #require(ModalPresence.isPresenting)
        let navigation = AppNavigation()
        navigation.requestNewThought()
        navigation.requestTab(.stats)
        navigation.requestSearch()
        navigation.requestSettings()
        #expect(navigation.newThoughtRequestCount == 0)
        #expect(navigation.selectedTab == .timeline)
        #expect(navigation.searchRequestCount == 0)
        #expect(!navigation.showSettings)
        navigation.requestEdit(thoughtID: UUID())
        #expect(navigation.editRequest != nil)
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
    }

    @Test func editRequestHoldsTheThoughtIdAndIgnoresASecond() {
        let navigation = AppNavigation()
        let first = UUID()
        navigation.requestEdit(thoughtID: first)
        #expect(navigation.editRequest?.id == first)
        navigation.requestEdit(thoughtID: UUID())
        #expect(navigation.editRequest?.id == first)
    }

    @Test func editSheetForAMissingThoughtDismissesItself() async throws {
        let container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let (window, root) = window()
        defer { window.isHidden = true }
        let sheet = UIHostingController(rootView: EditThoughtSheet(thoughtID: UUID()).modelContainer(container))
        present(sheet, over: root)
        try await Task.sleep(for: .milliseconds(300))
        #expect(root.presentedViewController == nil)
    }

    @Test func saveGateAllowsOneSaveAtATime() {
        var gate = SaveGate()
        let first = gate.begin()
        let second = gate.begin()
        #expect(first)
        #expect(!second)
    }

    @Test func saveGateReopensAfterAFailedSave() {
        var gate = SaveGate()
        let first = gate.begin()
        gate.fail()
        let retry = gate.begin()
        let duplicate = gate.begin()
        #expect(first)
        #expect(retry)
        #expect(!duplicate)
    }
}
