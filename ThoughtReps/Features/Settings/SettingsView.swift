import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays
    @State private var confirmWipe = false

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

                Section("Coming soon") {
                    Label("Daily reminder", systemImage: "bell")
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
