import Foundation
import Testing
@testable import ThoughtReps

private final class FakeSender: FeedbackSending, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(FeedbackKind, String, String)] = []
    var error: Error?

    func send(kind: FeedbackKind, message: String, email: String, diagnostics: FeedbackDiagnostics) async throws {
        if let error { throw error }
        lock.withLock { sent.append((kind, message, email)) }
    }
}

private let diagnostics = FeedbackDiagnostics(appVersion: "0.1.0 (1)", osVersion: "iOS 18.2", deviceModel: "iPhone17,1")

@MainActor
private func makeModel(_ sender: FakeSender = FakeSender()) -> (FeedbackFormModel, UserDefaults) {
    let defaults = UserDefaults(suiteName: "FeedbackTests-\(UUID().uuidString)")!
    return (FeedbackFormModel(kind: .bug, sender: sender, diagnostics: diagnostics, defaults: defaults), defaults)
}

@Suite("Feedback")
struct FeedbackTests {
    @Test func requestEncodesServerFieldNames() throws {
        let request = FeedbackRequest(challenge: "c", kind: .feature, message: "m", email: "a@b.co",
                                      appVersion: "1 (2)", osVersion: "iOS 18.2", deviceModel: "iPhone17,1")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String])
        #expect(json == ["challenge": "c", "kind": "feature", "message": "m", "email": "a@b.co",
                         "appVersion": "1 (2)", "osVersion": "iOS 18.2", "deviceModel": "iPhone17,1"])
        #expect(FeedbackKind.bug.rawValue == "bug")
    }

    @Test func sanitizeKeepsPrintableAsciiAndClips() {
        #expect(FeedbackDiagnostics.sanitize("1.0 (3)") == "1.0 (3)")
        #expect(FeedbackDiagnostics.sanitize("Caf\u{E9}\n\u{1F600}x") == "Cafx")
        #expect(FeedbackDiagnostics.sanitize("") == "unknown")
        #expect(FeedbackDiagnostics.sanitize("\u{E9}\u{E9}") == "unknown")
        #expect(FeedbackDiagnostics.sanitize(String(repeating: "a", count: 200)).count == 64)
    }

    @Test func currentDiagnosticsAreServerSafe() {
        let current = FeedbackDiagnostics.current()
        for value in [current.appVersion, current.osVersion, current.deviceModel] {
            #expect(value == FeedbackDiagnostics.sanitize(value))
        }
        #expect(current.osVersion.hasPrefix("iOS "))
    }

    @Test(arguments: [
        ("a@b.co", true), ("first.last@sub.example.com", true),
        ("", false), ("a@b", false), ("@b.co", false), ("a@@b.co", false),
        ("a b@c.co", false), ("a@b..co", false), ("a@b.", false),
        ("a@b.c", false), ("a@-b.co", false), ("a@b_c.co", false), ("a@b.c0", false),
        ("j\u{F6}rg@b.co", false), ("a@b.c\u{F6}", false), ("o'brien+tag@x-y.example.org", true),
        ("a.@b.co", false), (".a@b.co", false), ("a(@b.co", false),
    ])
    func emailValidation(email: String, valid: Bool) {
        #expect(FeedbackFormModel.isValidEmail(email) == valid)
    }

    @MainActor @Test func sendEnabledNeedsMessageAndEmail() {
        let (model, _) = makeModel()
        #expect(!model.canSend)
        model.message = "  \n "
        model.email = "a@b.co"
        #expect(!model.canSend)
        model.message = "hello"
        #expect(model.canSend)
        model.email = "nope"
        #expect(!model.canSend)
        model.email = "a@b.co"
        model.message = String(repeating: "x", count: FeedbackService.maxMessageLength + 1)
        #expect(!model.canSend)
    }

    @MainActor @Test func lengthCountsUTF16OfTrimmedMessage() {
        let (model, _) = makeModel()
        model.email = "a@b.co"
        model.message = "  " + String(repeating: "\u{1F600}", count: 2500) + "\n"
        #expect(model.messageLength == 5000)
        #expect(model.canSend)
        model.message = String(repeating: "\u{1F600}", count: 2501)
        #expect(model.messageLength == 5002)
        #expect(!model.canSend)
    }

    @MainActor @Test func successRemembersEmail() async {
        let sender = FakeSender()
        let (model, defaults) = makeModel(sender)
        model.message = "hello"
        model.email = " a@b.co "
        #expect(await model.send())
        #expect(sender.sent.count == 1)
        #expect(defaults.string(forKey: AppSettings.Key.feedbackEmail) == "a@b.co")
        #expect(FeedbackFormModel(kind: .feature, sender: sender, diagnostics: diagnostics, defaults: defaults).email == "a@b.co")
    }

    @MainActor @Test func failureKeepsTextAndReportsMessage() async {
        let sender = FakeSender()
        sender.error = APIError.rateLimited
        let (model, defaults) = makeModel(sender)
        model.message = "hello"
        model.email = "a@b.co"
        #expect(await !model.send())
        #expect(model.message == "hello")
        #expect(model.failure?.message == "You've reached today's feedback limit. Try again tomorrow.")
        #expect(defaults.string(forKey: AppSettings.Key.feedbackEmail) == nil)
        #expect(!model.isSending)
    }

    @Test func failureMessages() {
        #expect(FeedbackFailure(APIError.unsupported).message.contains("hello@thoughtreps.com"))
        #expect(FeedbackFailure(APIError.offline).message.contains("offline"))
        #expect(FeedbackFailure(APIError.server(status: 500)).message.contains("couldn't be sent"))
    }
}
