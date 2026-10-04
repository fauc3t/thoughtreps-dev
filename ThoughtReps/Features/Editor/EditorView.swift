import SwiftUI
import SwiftData

/// Create or edit a thought: Markdown body, attached blocks and its interval.
struct EditorView: View {
    enum Mode {
        case new(prefillTag: String? = nil)
        case edit(Thought)
    }

    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays

    @State private var text = ""
    @State private var drafts: [BlockDraft] = []
    @State private var intervalDays: Int? = nil
    @State private var hasLoaded = false
    @FocusState private var isBodyFocused: Bool

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var detectedTags: [TagParser.ParsedTag] {
        TagParser.parse(text)
    }

    private var intervalChoices: [Int] {
        Array(Set(IntervalOption.choices + [intervalDays].compactMap { $0 })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .focused($isBodyFocused)
                        .accessibilityLabel("Thought")
                } footer: {
                    if detectedTags.isEmpty {
                        Text("Markdown works here. Add #tags anywhere to file this thought.")
                    } else {
                        Text("Tags: " + detectedTags.map { "#\($0.display)" }.joined(separator: " "))
                    }
                }

                Section {
                    ForEach($drafts) { $draft in
                        BlockDraftEditor(draft: $draft)
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(BlockKind.allCases) { kind in
                            Button {
                                drafts.append(BlockDraft(kind: kind))
                            } label: {
                                Label(kind.label, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add block", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Blocks")
                } footer: {
                    Text("Blurred blocks stay hidden until you tap them. Good for answers to quiz yourself on.")
                }

                Section("Schedule") {
                    Picker("Comes back every", selection: $intervalDays) {
                        Text("Default (\(defaultIntervalDays) days)").tag(Int?.none)
                        ForEach(intervalChoices, id: \.self) { days in
                            Text(IntervalOption.label(days)).tag(Int?.some(days))
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New thought" : "Edit thought")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedText.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    FormatBar(text: $text)
                }
            }
            .onAppear { load() }
        }
        .interactiveDismissDisabled(!trimmedText.isEmpty && isNew)
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch mode {
        case let .new(prefillTag):
            if let prefillTag {
                text = "\n\n#\(prefillTag)"
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                isBodyFocused = true
            }
        case let .edit(thought):
            text = thought.body
            intervalDays = thought.intervalDays
            drafts = thought.sortedBlocks.map {
                BlockDraft(id: $0.id, kind: $0.kind, title: $0.title ?? "", content: $0.content)
            }
        }
    }

    private func save() {
        let store = ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays)
        switch mode {
        case .new:
            store.create(body: trimmedText, blocks: drafts, intervalDays: intervalDays, now: .now)
        case let .edit(thought):
            store.update(thought, body: trimmedText, blocks: drafts, intervalDays: intervalDays, now: .now)
        }
        dismiss()
    }
}

/// Keyboard toolbar that inserts Markdown at the end of the text.
/// (Selection-aware formatting comes with the Milestone 3 editor work.)
struct FormatBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 0) {
            button("Heading", systemImage: "number.square") { appendLine("# ") }
            button("Bold", systemImage: "bold") { append("**bold**") }
            button("Italic", systemImage: "italic") { append("_italic_") }
            button("List", systemImage: "list.bullet") { appendLine("- ") }
            button("Task", systemImage: "checklist") { appendLine("- [ ] ") }
            button("Code", systemImage: "chevron.left.forwardslash.chevron.right") { append("`code`") }
            button("Tag", systemImage: "tag") { append("#") }
        }
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    /// Appends inline, adding a space if the text doesn't already end in whitespace.
    private func append(_ snippet: String) {
        if let last = text.last, !last.isWhitespace {
            text += " "
        }
        text += snippet
    }

    /// Appends on a new line.
    private func appendLine(_ prefix: String) {
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += prefix
    }
}

#Preview {
    EditorView(mode: .new())
        .modelContainer(PreviewData.container)
}
