import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays
    @AppStorage(AppSettings.Key.reminderEnabled) private var reminderEnabled = false
    @AppStorage(AppSettings.Key.reminderMinutes) private var reminderMinutes = AppSettings.defaultReminderMinutes
    @AppStorage(AppSettings.Key.thoughtFont) private var thoughtFont = ThoughtFont.paperMono
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmWipe = false
    @State private var testReminderSent: Bool?
    @State private var feedbackKind: FeedbackKind?
    @State private var feedbackSent = false
    @State private var showFeedbackThanks = false
    @State private var backup = BackupModel.shared
    @State private var exportLink = ExportLinkModel.shared
    @State private var linkImport = ExportLinkImportModel.shared
    @State private var showImporter = false

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

                Section {
                    Picker("Thought text", selection: $thoughtFont) {
                        ForEach(ThoughtFont.allCases) { font in
                            Text(font.label).tag(font)
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The font for your thoughts, card previews and the editor. Titles stay the same.")
                }

                Section("Send Feedback") {
                    Button("Request a Feature") { feedbackKind = .feature }
                    Button("Report a Problem") { feedbackKind = .bug }
                }

                Section {
                    Button {
                        Task { await backup.export(from: context.container) }
                    } label: {
                        HStack {
                            Label("Export…", systemImage: "square.and.arrow.up")
                            if let progress = backup.exportProgress {
                                Spacer()
                                ProgressView(value: progress)
                                    .frame(width: 80)
                                    .accessibilityLabel("Export progress")
                            }
                        }
                    }
                    .disabled(backup.isBusy)
                    .accessibilityHint("Saves all thoughts and images to a file you can keep or share")
                    Menu {
                        Button("From a File…") { showImporter = true }
                        Button("From a Link…") { Task { await linkImport.present() } }
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(backup.isBusy)
                    .accessibilityHint("Adds thoughts from a Thought Reps export file or link")
                    ExportLinkRows(backup: backup, exportLink: exportLink, container: context.container)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Exports every thought, tag and image to one file. Importing adds what's missing and keeps the newer version of a thought you already have.")
                }

                #if DEBUG
                if !ScreenshotMode.isActive {
                    Section("Developer") {
                        Button("Add sample thoughts") {
                            SampleData.insert(into: context, now: .now)
                        }
                        Button("Send test reminder in 5 seconds") {
                            Task {
                                testReminderSent = await NotificationScheduler.sendTestReminder(context: context, now: .now)
                                notificationStatus = await NotificationScheduler.authorizationStatus()
                            }
                        }
                        Button("Delete all thoughts", role: .destructive) {
                            confirmWipe = true
                        }
                    }
                }
                #endif

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                }
            }
            .task { notificationStatus = await NotificationScheduler.authorizationStatus() }
            .task { await exportLink.refresh() }
            .onAppear { backup.host = .settings }
            .onDisappear { backup.host = .root }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.thoughtRepsExport, .zip]) { result in
                switch result {
                case .success(let url): backup.beginImport(from: url, container: context.container)
                case .failure(let error): backup.problem = error.localizedDescription
                }
            }
            .sheet(item: Binding(get: { backup.exportedFile }, set: { backup.exportedFile = $0 }), onDismiss: { backup.finishSharing() }) { file in
                ActivityView(url: file.url)
                    .presentationDetents([.medium, .large])
            }
            .alert("Backup problem", isPresented: Binding(get: { backup.problem != nil }, set: { if !$0 { backup.problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(backup.problem ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await exportLink.refresh() }
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
            .sheet(item: $feedbackKind, onDismiss: {
                showFeedbackThanks = feedbackSent
                feedbackSent = false
            }) { kind in
                FeedbackFormView(kind: kind) { feedbackSent = true }
            }
            .alert("Thanks for your feedback", isPresented: $showFeedbackThanks) {
                Button("OK") {}
            } message: {
                Text("Your message was sent.")
            }
            .alert(
                testReminderSent == true ? "Test reminder scheduled" : "Couldn't send a test reminder",
                isPresented: Binding(get: { testReminderSent != nil }, set: { if !$0 { testReminderSent = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(testReminderSent == true
                    ? "It arrives in 5 seconds. Lock your phone to see it on the Lock Screen."
                    : "Notifications are off for Thought Reps. Turn them on in iOS Settings.")
            }
            .backupImportSheet(backup, host: .settings)
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
