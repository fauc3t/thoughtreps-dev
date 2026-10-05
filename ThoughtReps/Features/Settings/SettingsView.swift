import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays
    @AppStorage(AppSettings.Key.reminderEnabled) private var reminderEnabled = false
    @AppStorage(AppSettings.Key.reminderMinutes) private var reminderMinutes = AppSettings.defaultReminderMinutes
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmWipe = false

    private var reminderTime: Binding<Date> {
        Binding(
            get: { ReminderTime.date(minutes: reminderMinutes, now: .now) },
            set: { reminderMinutes = ReminderTime.minutes(from: $0) }
        )
    }

    private func reschedule() {
        Task { await NotificationScheduler.reschedule(context: context, now: .now) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $defaultIntervalDays, in: 1...90) {
                        LabeledContent("Default interval", value: "\(defaultIntervalDays) \(defaultIntervalDays == 1 ? "day" : "days")")
                    }
                } header: {
                    Text("Resurfacing")
                } footer: {
                    Text("How long a thought waits before coming back, unless it has its own interval. Applies to future views.")
                }

                Section {
                    Toggle("Daily reminder", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                    if notificationStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    if notificationStatus == .denied {
                        Text("Notifications are off for Thought Reps in iOS Settings. Turn them on there to get reminders.")
                    } else {
                        Text("One notification at this time on days when thoughts are back, and a few more if you're away for a while. Pinned thoughts aren't counted.")
                    }
                }

                Section("Coming soon") {
                    Label("Export & import", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(.secondary)

                #if DEBUG
                Section("Developer") {
                    Button("Add sample thoughts") {
                        SampleData.insert(into: context, now: .now)
                    }
                    Button("Delete all thoughts", role: .destructive) {
                        confirmWipe = true
                    }
                }
                #endif

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                }
            }
            .task { notificationStatus = await NotificationScheduler.authorizationStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { notificationStatus = await NotificationScheduler.authorizationStatus() }
            }
            .onChange(of: reminderEnabled) { _, enabled in
                guard enabled else { return reschedule() }
                Task {
                    if await NotificationScheduler.requestAuthorization() {
                        await NotificationScheduler.reschedule(context: context, now: .now)
                    } else {
                        reminderEnabled = false
                    }
                    notificationStatus = await NotificationScheduler.authorizationStatus()
                }
            }
            .onChange(of: reminderMinutes) { reschedule() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete every thought and tag?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) {
                    ThoughtStore(context: context).deleteAll()
                }
            }
        }
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
