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
    @State private var isPickingInterval = false
    @State private var hasLoaded = false
    @State private var tagUseCounts: [String: Int] = [:]
    @State private var saveErrors = SaveErrorCenter()
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
            let count = tagUseCounts[tag.name] ?? 0
            return count > 0 ? TagSuggester.Candidate(key: tag.name, display: tag.displayName, count: count) : nil
        }
        return TagSuggester.suggestions(
            for: token.partial,
            from: candidates,
            excluding: Set(TagParser.parse(rest).map(\.key))
        )
    }

    /// Nothing is saved while the editor is open, so these counts stay valid until it closes.
    private func loadTagUseCounts() {
        tagUseCounts = Dictionary(
            allTags.map { ($0.name, ThoughtCounts.count(ThoughtCounts.any(tag: $0.name), in: context)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var intervalSummary: String {
        guard let intervalDays else { return "Default (\(defaultIntervalDays) days)" }
        return IntervalDuration(days: intervalDays).label
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
                    LabeledContent("Comes back every") {
                        Menu {
                            Picker("Interval", selection: $intervalDays) {
                                Text("Default (\(defaultIntervalDays) days)").tag(Int?.none)
                                ForEach(IntervalOption.choices(including: intervalDays), id: \.self) { days in
                                    Text(IntervalDuration(days: days).label).tag(Int?.some(days))
                                }
                            }
                            .pickerStyle(.inline)
                            Button("Custom…") { isPickingInterval = true }
                        } label: {
                            Text(intervalSummary)
                        }
                    }
                }
            }
            .saveErrorAlert(saveErrors)
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
            .sheet(isPresented: $isPickingInterval) {
                IntervalPickerSheet(initialDays: intervalDays ?? defaultIntervalDays) { days in
                    if intervalDays == nil && days == defaultIntervalDays { return }
                    intervalDays = days
                }
            }
            .onAppear {
                load()
                loadTagUseCounts()
            }
            .onChange(of: text) { old, new in continueList(from: old, to: new) }
        }
        .interactiveDismissDisabled(!trimmedText.isEmpty && isNew)
    }

    private func continueList(from old: String, to new: String) {
        var cursor: String.Index?
        if let selection, case let .selection(range) = selection.indices, range.isEmpty { cursor = range.upperBound }
        guard let continued = MarkdownFormatter.continueList(from: old, to: new, cursor: cursor) else { return }
        text = continued.text
        selection = TextSelection(insertionPoint: continued.cursor)
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

    /// Dismisses only if the save succeeded, so a failed save keeps the draft on screen.
    /// Uses its own error center because an alert on the root view doesn't show over this sheet.
    private func save() {
        let store = ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays, saveErrors: saveErrors)
        let saved: Bool
        switch mode {
        case .new:
            let thought = store.create(body: trimmedText, blocks: drafts, intervalDays: intervalDays, now: .now)
            saved = thought.modelContext != nil
        case let .edit(thought):
            saveErrors.note = "Some changes may have been saved. Tap Save to finish."
            saved = store.update(thought, body: trimmedText, blocks: drafts, intervalDays: intervalDays, now: .now)
        }
        if saved {
            dismiss()
        }
    }
}

/// Keyboard toolbar that formats Markdown at the cursor or selection.
struct FormatBar: View {
    @Binding var text: String
    @Binding var selection: TextSelection?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                button("Heading", systemImage: "number.square") { apply(.heading) }
                button("Bold", systemImage: "bold") { apply(.bold) }
                button("Italic", systemImage: "italic") { apply(.italic) }
                button("List", systemImage: "list.bullet") { apply(.bullet) }
                button("Task", systemImage: "checklist") { apply(.task) }
                button("Code", systemImage: "chevron.left.forwardslash.chevron.right") { apply(.code) }
                button("Tag", systemImage: "tag") { insertHash() }
            }
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    /// The selected range, or an insertion point at the end of the text if there is no selection.
    private var currentRange: Range<String.Index> {
        if let selection, case let .selection(range) = selection.indices { return range }
        return text.endIndex..<text.endIndex
    }

    private func apply(_ style: MarkdownFormatter.Inline) {
        commit(MarkdownFormatter.toggle(style, in: text, selection: currentRange))
    }

    private func apply(_ prefix: MarkdownFormatter.LinePrefix) {
        commit(MarkdownFormatter.toggle(prefix, in: text, selection: currentRange))
    }

    private func commit(_ edit: MarkdownFormatter.Edit) {
        text = edit.text
        selection = TextSelection(range: edit.selection)
    }

    /// Inserts `#` at the cursor (end of text if there is none) so suggestions appear right away.
    private func insertHash() {
        let inserted = TagSuggester.insertHash(in: text, at: currentRange.upperBound)
        text = inserted.text
        selection = TextSelection(insertionPoint: inserted.cursor)
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
