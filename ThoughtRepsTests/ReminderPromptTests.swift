import Foundation
import Testing
import UserNotifications
@testable import ThoughtReps

extension ReminderPrompt {
    /// A prompt backed by an empty, uniquely named suite so tests never touch `.standard`.
    static func throwaway() -> ReminderPrompt {
        let name = "ReminderPromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ReminderPrompt(defaults: defaults)
    }
}

@Suite("ReminderPrompt")
struct ReminderPromptTests {
    @Test func offersFirstTimeWhenNotDetermined() {
        #expect(ReminderPrompt.throwaway().shouldOffer(status: .notDetermined))
    }

    @Test func doesNotOfferAfterAsked() {
        let prompt = ReminderPrompt.throwaway()
        prompt.markAsked()
        #expect(prompt.wasAsked)
        #expect(!prompt.shouldOffer(status: .notDetermined))
    }

    @Test func doesNotOfferWhenAlreadyEnabled() {
        let prompt = ReminderPrompt.throwaway()
        prompt.defaults.set(true, forKey: AppSettings.Key.reminderEnabled)
        #expect(!prompt.shouldOffer(status: .notDetermined))
    }

    @Test func enablingRemindersSetsFlagAndStopsOffering() {
        let prompt = ReminderPrompt.throwaway()
        prompt.enableReminders()
        #expect(prompt.defaults.bool(forKey: AppSettings.Key.reminderEnabled))
        #expect(!prompt.shouldOffer(status: .notDetermined))
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .denied, .provisional])
    func doesNotOfferOnceOSHasDecided(status: UNAuthorizationStatus) {
        #expect(!ReminderPrompt.throwaway().shouldOffer(status: status))
    }
}
