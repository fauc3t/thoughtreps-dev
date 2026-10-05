import SwiftUI

struct FeedbackFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: FeedbackFormModel
    let onSent: () -> Void

    init(kind: FeedbackKind, onSent: @escaping () -> Void) {
        _model = State(initialValue: FeedbackFormModel(kind: kind))
        self.onSent = onSent
    }

    private var title: String {
        model.kind == .feature ? "Request a Feature" : "Report a Problem"
    }

    private var prompt: String {
        model.kind == .feature ? "What would you like Thought Reps to do?" : "What went wrong?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $model.message)
                        .frame(minHeight: 140)
                        .accessibilityLabel(prompt)
                } header: {
                    Text(prompt)
                } footer: {
                    Text("\(model.messageLength) / \(FeedbackService.maxMessageLength)")
                        .foregroundStyle(model.messageLength > FeedbackService.maxMessageLength ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("\(model.messageLength) of \(FeedbackService.maxMessageLength) characters")
                }

                Section {
                    TextField("Email", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Your email")
                } footer: {
                    Text("So we can reply to you.")
                }

                Section {
                    LabeledContent("App version", value: model.diagnostics.appVersion)
                    LabeledContent("iOS version", value: model.diagnostics.osVersion)
                    LabeledContent("Device model", value: model.diagnostics.deviceModel)
                } header: {
                    Text("Included with your message")
                } footer: {
                    Text("Your thoughts are never attached.")
                }
            }
            .disabled(model.isSending)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isSending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        ProgressView()
                            .accessibilityLabel("Sending")
                    } else {
                        Button("Send") {
                            Task {
                                if await model.send() {
                                    onSent()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!model.canSend)
                    }
                }
            }
            .alert(
                "Couldn't send feedback",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(model.failure?.message ?? "")
            }
        }
    }
}
