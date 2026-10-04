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

    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var text = ""
    @State private var selection: TextSelection?
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

    /// The `#partial` at the cursor, when the selection is a plain insertion point.
    private var activeToken: (range: Range<String.Index>, partial: String)? {
        guard let selection, case let .selection(range) = selection.indices, range.isEmpty else { return nil }
        return TagSuggester.activeToken(in: text, cursor: range.upperBound)
    }

    private func suggestions(for token: (range: Range<String.Index>, partial: String)) -> [TagSuggester.Candidate] {
        var rest = text
        rest.removeSubrange(token.range)
        let candidates = allTags.compactMap { tag -> TagSuggester.Candidate? in
            let count = tag.thoughts?.count ?? 0
            return count > 0 ? TagSuggester.Candidate(key: tag.name, display: tag.displayName, count: count) : nil
        }
        return TagSuggester.suggestions(
            for: token.partial,
            from: candidates,
            excluding: Set(TagParser.parse(rest).map(\.key))
        )
    }

    private var intervalChoices: [Int] {
        Array(Set(IntervalOption.choices + [intervalDays].compactMap { $0 })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text, selection: $selection)
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
                    if let token = activeToken, case let found = suggestions(for: token), !found.isEmpty {
                        SuggestionBar(suggestions: found, tags: allTags) { candidate in
                            let applied = TagSuggester.apply(candidate, replacing: token.range, in: text)
                            text = applied.text
                            selection = TextSelection(insertionPoint: applied.cursor)
                        }
                    } else {
                        FormatBar(text: $text, selection: $selection)
                    }
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
    @Binding var selection: TextSelection?

    var body: some View {
        HStack(spacing: 0) {
            button("Heading", systemImage: "number.square") { appendLine("# ") }
            button("Bold", systemImage: "bold") { append("**bold**") }
            button("Italic", systemImage: "italic") { append("_italic_") }
            button("List", systemImage: "list.bullet") { appendLine("- ") }
            button("Task", systemImage: "checklist") { appendLine("- [ ] ") }
            button("Code", systemImage: "chevron.left.forwardslash.chevron.right") { append("`code`") }
            button("Tag", systemImage: "tag") { insertHash() }
        }
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    /// Inserts `#` at the cursor (end of text if there is none) so suggestions appear right away.
    private func insertHash() {
        var cursor = text.endIndex
        if let selection, case let .selection(range) = selection.indices {
            cursor = range.upperBound
        }
        let inserted = TagSuggester.insertHash(in: text, at: cursor)
        text = inserted.text
        selection = TextSelection(insertionPoint: inserted.cursor)
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

/// Keyboard toolbar row of existing tags that complete the `#partial` being typed.
struct SuggestionBar: View {
    let suggestions: [TagSuggester.Candidate]
    let tags: [Tag]
    let onSelect: (TagSuggester.Candidate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.key) { candidate in
                    Button { onSelect(candidate) } label: { chip(candidate) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tag \(candidate.display), \(candidate.count) \(candidate.count == 1 ? "thought" : "thoughts")")
                }
            }
        }
    }

    private func chip(_ candidate: TagSuggester.Candidate) -> some View {
        let color = tags.first { $0.name == candidate.key }.map(TagColor.color(for:)) ?? .secondary
        return HStack(spacing: 4) {
            Text("#\(candidate.display)")
                .font(.caption.weight(.medium))
            Text("\(candidate.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

#Preview {
    EditorView(mode: .new())
        .modelContainer(PreviewData.container)
}
