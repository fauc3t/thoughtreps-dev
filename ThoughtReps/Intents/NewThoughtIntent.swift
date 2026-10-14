import AppIntents

/// Opens the app on a new, empty thought; the Action button, Siri and Shortcuts all run this.
struct NewThoughtIntent: AppIntent {
    static let title: LocalizedStringResource = "New Thought"
    static let description = IntentDescription("Opens Thought Reps on a new, empty thought.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigation.shared.requestNewThought(skipsTagPrefill: true)
        return .result()
    }
}
