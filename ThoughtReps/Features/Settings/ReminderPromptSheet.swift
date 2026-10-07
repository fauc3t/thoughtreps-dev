import SwiftUI
import SwiftData

/// One-time offer to turn on daily reminders, shown before the system permission dialog.
struct ReminderPromptSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var working = false
    @State private var detent: PresentationDetent = .height(300)

    private var timeText: String {
        ReminderTime.date(minutes: AppSettings.reminderMinutes, now: .now)
            .formatted(date: .omitted, time: .shortened)
    }

    private func turnOn() {
        working = true
        Task {
            if await NotificationScheduler.requestAuthorization() {
                ReminderPrompt().enableReminders()
                await NotificationScheduler.reschedule(context: context, now: .now)
            }
            dismiss()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Want a nudge when it comes back?")
                    .font(.archivo(22, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("One reminder a day at \(timeText), only when something's due.")
                    .font(.archivo(16, relativeTo: .body))
                    .foregroundStyle(Color.muted)
                Spacer(minLength: 12)
                Button(action: turnOn) {
                    Text("Turn on reminders")
                        .font(.archivo(17, relativeTo: .body))
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(InkPressStyle())
                .disabled(working)
                Button { dismiss() } label: {
                    Text("Not now")
                        .font(.archivo(17, relativeTo: .body))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(InkPressStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .background(Color.paper)
        .onAppear {
            ReminderPrompt().markAsked()
            if dynamicTypeSize.isAccessibilitySize { detent = .medium }
        }
        .presentationDetents([.height(300), .medium], selection: $detent)
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ReminderPromptSheet()
            .modelContainer(PreviewData.container)
    }
}
