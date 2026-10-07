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
    @State private var inlineDrafts: [ImageDraft] = []
    @State private var blockSelections: [UUID: TextSelection] = [:]
    @State private var activeField: EditorField = .body
    @State private var intake = ImageIntake()
    @FocusState private var focus: EditorField?

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var markdownTexts: [String] {
        [text] + drafts.filter { $0.kind == .markdown }.map(\.content)
    }

    private var detectedTags: [TagParser.ParsedTag] {
        TagParser.parse(all: markdownTexts)
    }

    private func textBinding(for field: EditorField) -> Binding<String> {
        switch field {
        case .body:
            $text
        case let .block(id):
            Binding(
                get: { drafts.first { $0.id == id }?.content ?? "" },
                set: { new in
                    if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].content = new }
                }
            )
        }
    }

    private func selectionBinding(for field: EditorField) -> Binding<TextSelection?> {
        switch field {
        case .body:
            $selection
        case let .block(id):
            Binding(get: { blockSelections[id] }, set: { blockSelections[id] = $0 })
        }
    }

    /// The `#partial` at the cursor of the focused field, when the selection is a plain insertion point.
    private var activeToken: (field: EditorField, range: Range<String.Index>, partial: String)? {
        guard let field = focus,
              let selection = selectionBinding(for: field).wrappedValue,
              case let .selection(range) = selection.indices, range.isEmpty,
              let token = TagSuggester.activeToken(in: textBinding(for: field).wrappedValue, cursor: range.upperBound)
        else { return nil }
        return (field, token.range, token.partial)
    }

    private func suggestions(for token: (field: EditorField, range: Range<String.Index>, partial: String)) -> [TagSuggester.Candidate] {
        var rest = textBinding(for: token.field).wrappedValue
        rest.removeSubrange(token.range)
        var otherTexts = drafts.filter { $0.kind == .markdown && EditorField.block($0.id) != token.field }.map(\.content)
        if token.field != .body { otherTexts.append(text) }
        let present = TagParser.parse(all: [rest] + otherTexts).map(\.key)
        let candidates = allTags.compactMap { tag -> TagSuggester.Candidate? in
            let count = tagUseCounts[tag.name] ?? 0
            return count > 0 ? TagSuggester.Candidate(key: tag.name, display: tag.displayName, count: count) : nil
        }
        return TagSuggester.suggestions(
            for: token.partial,
            from: candidates,
            excluding: Set(present)
        )
    }

    /// Nothing is saved while the editor is open, so these counts stay valid until it closes.
    private func loadTagUseCounts() {
        tagUseCounts = Dictionary(
            allTags.map { ($0.name, ThoughtCounts.count(ThoughtCounts.any(tag: $0.name), in: context)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Images already stored on the thought being edited.
    private var storedImages: [UUID: ImageAsset] {
        guard case let .edit(thought) = mode else { return [:] }
        return Dictionary((thought.images ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Inserts at the cursor of the field last focused (the body if that block has since been deleted).
    private func addInlineImages(_ added: [ImageDraft]) {
        var field = activeField
        if case let .block(id) = field, !drafts.contains(where: { $0.id == id }) { field = .body }
        let fieldText = textBinding(for: field)
        let fieldSelection = selectionBinding(for: field)
        for draft in added {
            inlineDrafts.append(draft)
            let current = fieldText.wrappedValue
            var cursor = current.endIndex
            if let selection = fieldSelection.wrappedValue, case let .selection(range) = selection.indices,
               range.upperBound <= current.endIndex {
                cursor = range.upperBound
            }
            let inserted = ImageToken.inserting(draft.id, into: current, at: cursor)
            fieldText.wrappedValue = inserted.text
            fieldSelection.wrappedValue = TextSelection(insertionPoint: inserted.cursor)
        }
    }

    /// Looks the block up by id because it may have moved or been deleted while the image processed.
    private func addGalleryImages(to blockID: UUID, _ added: [ImageDraft]) {
        guard let index = drafts.firstIndex(where: { $0.id == blockID }) else { return }
        drafts[index].images.append(contentsOf: added)
    }

    private func removeInlineImage(_ id: UUID) {
        text = ImageToken.removing(id, from: text)
        selection = nil
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
                        .focused($focus, equals: .body)
                        .accessibilityLabel("Thought")
                    ImageProcessingIndicator(intake: intake)
                    let thumbnails = inlineThumbnails(in: text, drafts: inlineDrafts, stored: storedImages)
                    if !thumbnails.isEmpty {
                        InlineImageStrip(thumbnails: thumbnails, remove: removeInlineImage)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 8))
                    }
                } footer: {
                    if detectedTags.isEmpty {
                        Text("Markdown works here. Add #tags anywhere to file this thought.")
                    } else {
                        Text("Tags: " + detectedTags.map { "#\($0.display)" }.joined(separator: " "))
                    }
                }

                Section {
                    ForEach($drafts) { $draft in
                        BlockDraftEditor(
                            draft: $draft,
                            selection: selectionBinding(for: .block(draft.id)),
                            focus: $focus,
                            storedImages: storedImages,
                            inlineDrafts: inlineDrafts
                        ) { addGalleryImages(to: $0, $1) }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(BlockKind.allCases) { kind in
                            Button {
                                addBlock(kind)
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
                    Text("Add more text or a gallery. Turn on blur to hide an answer until you tap it.")
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
            .imageIntake(intake, onAdd: addInlineImages)
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
                            let applied = TagSuggester.apply(candidate, replacing: token.range, in: textBinding(for: token.field).wrappedValue)
                            textBinding(for: token.field).wrappedValue = applied.text
                            selectionBinding(for: token.field).wrappedValue = TextSelection(insertionPoint: applied.cursor)
                        }
                    } else if let field = focus {
                        FormatBar(text: textBinding(for: field), selection: selectionBinding(for: field), intake: intake)
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
            .onChange(of: text) { old, new in
                continueList(in: .body, from: old, to: new)
            }
            .onChange(of: drafts.map(\.content)) { old, new in
                guard let index = EditorField.changedIndex(from: old, to: new) else { return }
                continueList(in: .block(drafts[index].id), from: old[index], to: new[index])
            }
            .onChange(of: focus) { _, new in
                if let new { activeField = new }
            }
        }
        .interactiveDismissDisabled(!trimmedText.isEmpty && isNew)
    }

    private func continueList(in field: EditorField, from old: String, to new: String) {
        let selection = selectionBinding(for: field)
        var cursor: String.Index?
        if let current = selection.wrappedValue, case let .selection(range) = current.indices, range.isEmpty {
            cursor = range.upperBound
        }
        guard let continued = MarkdownFormatter.continueList(from: old, to: new, cursor: cursor) else { return }
        textBinding(for: field).wrappedValue = continued.text
        selection.wrappedValue = TextSelection(insertionPoint: continued.cursor)
    }

    private func addBlock(_ kind: BlockKind) {
        let draft = BlockDraft(kind: kind)
        drafts.append(draft)
        if kind == .markdown {
            Task { @MainActor in focus = .block(draft.id) }
        }
    }

    private var prefilledText: String? {
        guard case let .new(prefillTag) = mode, let prefillTag else { return nil }
        return "\n\n#\(prefillTag)"
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch mode {
        case .new:
            if let prefilledText {
                text = prefilledText
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard let prefilledText else {
                    focus = .body
                    return
                }
                // TextEditor doesn't report its focus-time cursor placement and overwrites the cursor on focus, so write the start before focus and again 100 ms after.
                selection = TextSelection(insertionPoint: text.startIndex)
                focus = .body
                try? await Task.sleep(for: .milliseconds(100))
                if text == prefilledText {
                    selection = TextSelection(insertionPoint: text.startIndex)
                }
            }
        case let .edit(thought):
            text = thought.body
            intervalDays = thought.intervalDays
            drafts = BlockDraft.drafts(for: thought)
        }
    }

    /// Dismisses only if the save succeeded, so a failed save keeps the draft on screen.
    /// Uses its own error center because an alert on the root view doesn't show over this sheet.
    private func save() {
        let store = ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays, saveErrors: saveErrors)
        let saved: Bool
        switch mode {
        case .new:
            let thought = store.create(body: trimmedText, blocks: drafts, images: inlineDrafts, intervalDays: intervalDays, now: .now)
            saved = thought.modelContext != nil
        case let .edit(thought):
            saveErrors.note = "Some changes may have been saved. Tap Save to finish."
            saved = store.update(thought, body: trimmedText, blocks: drafts, images: inlineDrafts, intervalDays: intervalDays, now: .now)
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
    let intake: ImageIntake

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
                Menu {
                    ImageSourceButtons(intake: intake)
                } label: {
                    Image(systemName: "photo")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Add image")
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
