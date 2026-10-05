import Foundation
import Observation

@MainActor
@Observable
final class FeedbackFormModel {
    let kind: FeedbackKind
    let diagnostics: FeedbackDiagnostics
    var message = ""
    var email: String
    private(set) var isSending = false
    var failure: FeedbackFailure?

    private let sender: FeedbackSending
    private let defaults: UserDefaults

    init(
        kind: FeedbackKind,
        sender: FeedbackSending = FeedbackService(),
        diagnostics: FeedbackDiagnostics = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.kind = kind
        self.sender = sender
        self.diagnostics = diagnostics
        self.defaults = defaults
        email = defaults.string(forKey: AppSettings.Key.feedbackEmail) ?? ""
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The server counts UTF-16 code units of the trimmed message.
    var messageLength: Int { message.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }

    var canSend: Bool {
        !isSending
            && messageLength > 0
            && messageLength <= FeedbackService.maxMessageLength
            && Self.isValidEmail(trimmedEmail)
    }

    /// Returns true when the message was sent; on failure `failure` is set and the text is kept.
    func send() async -> Bool {
        guard canSend else { return false }
        isSending = true
        defer { isSending = false }
        do {
            try await sender.send(kind: kind, message: message, email: trimmedEmail, diagnostics: diagnostics)
            defaults.set(trimmedEmail, forKey: AppSettings.Key.feedbackEmail)
            return true
        } catch {
            failure = FeedbackFailure(error)
            return false
        }
    }

    /// Mirrors the server's zod 4 `z.email()` pattern, plus its 254-character limit.
    nonisolated static func isValidEmail(_ value: String) -> Bool {
        let pattern = #/(?:[A-Za-z0-9_'+\-]+\.)*[A-Za-z0-9_'+\-]*[A-Za-z0-9_+-]@(?:[A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}/#
        return value.utf16.count <= 254 && value.wholeMatch(of: pattern) != nil
    }
}

struct FeedbackFailure: Equatable {
    let message: String

    init(_ error: Error) {
        switch error as? APIError {
        case .rateLimited:
            message = "You've reached today's feedback limit. Try again tomorrow."
        case .unsupported:
            message = "Feedback can't be sent from this device. Email hello@thoughtreps.com instead."
        case .offline:
            message = "You appear to be offline. Check your connection and try again."
        default:
            message = "Your message couldn't be sent. It's still here, so you can try again."
        }
    }
}
