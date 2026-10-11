import SwiftUI
import SwiftData

/// Create or edit a thought: Markdown body, attached blocks and its interval.
struct EditorView: View {
    enum Mode {
        case new(prefillTag: String? = nil)
        case edit(Thought)
    }

    let mode: Mode
    var onCreated: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays

    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var drafts: [BlockDraft] = []
    @State private var intervalDays: Int? = nil
    @State private var learn = false
    @State private var isPickingInterval = false
    @State private var hasLoaded = false
    @State private var tagUseCounts: [String: Int] = [:]
    @State private var saveErrors = SaveErrorCenter()
    @State private var inlineDrafts: [ImageDraft] = []
    @State private var blockSelections: [UUID: TextSelection] = [:]
    @State private var activeField: EditorField = .body
    @State private var intake = ImageIntake()
    /// The Markdown field that is the first responder; each field's text view keeps this in step.
    @State private var focus: EditorField?
    @State private var pendingNewBlockID: UUID?
    @State private var bodyLoadToken = 0
    @State private var bodyHeight = MarkdownTextView.minHeight
    @State private var formWidth: CGFloat = 0
    @State private var isConfirmingDiscard = false
    @State private var saveGate = SaveGate()
    @State private var processingBlockIDs: Set<UUID> = []
    @State private var openedText = ""
    @State private var openedDrafts: [BlockDraft] = []
    @State private var openedIntervalDays: Int?
    @State private var openedLearn = false

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Differs from what the editor opened with. Compares against the loaded state, so a prefilled tag alone isn't a change.
    private var isDirty: Bool {
        text != openedText || drafts != openedDrafts || intervalDays != openedIntervalDays || learn != openedLearn || !inlineDrafts.isEmpty
    }

    /// Images are still being processed here or in a gallery block that is still in the editor.
    private var isProcessingImages: Bool {
        intake.isProcessing || !processingBlockIDs.isDisjoint(with: drafts.map(\.id))
    }

    private var markdownTexts: [String] {
        [text] + drafts.filter { $0.kind == .markdown }.map(\.content)
    }

    private var detectedTags: [TagParser.ParsedTag] {
        TagParser.parse(all: markdownTexts)
    }

    /// What the Section footer said before the body became edge-to-edge rows: a hint, or the tags found.
    private var tagsFooter: String {
        detectedTags.isEmpty
            ? "Markdown works here. Add #tags anywhere to file this thought."
            : "Tags: " + detectedTags.map { "#\($0.display)" }.joined(separator: " ")
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

    /// Adds a block; `pendingNewBlockID` then drives scrolling to it and focusing its Markdown field.
    private func addBlock(_ kind: BlockKind) {
        pendingNewBlockID = drafts.addBlock(kind)
    }

    /// Thumbnail bytes for an image token in any Markdown field: only this thought's own images and the new inline ones.
    private func thumbnailData(for id: UUID) -> Data? {
        if let draft = inlineDrafts.first(where: { $0.id == id }), let processed = draft.processed {
            return processed.thumbnailData
        }
        guard case let .edit(thought) = mode,
              let asset = thought.images?.first(where: { $0.id == id }), asset.isInline else { return nil }
        return asset.thumbnailData
    }

    /// The keyboard accessory of one Markdown field: tag suggestions while it has a `#partial` at its cursor,
    /// otherwise the format bar. Every field gets its own, acting on its own text.
    private func accessory(for field: EditorField) -> AnyView {
        // Only the focused field can have a `#partial` at its cursor, so the others never look for one.
        if focus == field, let token = activeToken, case let found = suggestions(for: token), !found.isEmpty {
            return AnyView(SuggestionBar(suggestions: found, tags: allTags) { candidate in
                EditorField.applyTag(candidate, replacing: token.range, in: textBinding(for: field), selection: selectionBinding(for: field))
            })
        }
        return AnyView(FormatBar(text: textBinding(for: field), selection: selectionBinding(for: field), intake: intake) { addBlock($0) })
    }

    /// Inserts at the cursor of the field last focused (the body if that block has since been deleted).
    private func addInlineImages(_ added: [ImageDraft]) {
        let field = EditorField.resolve(activeField, drafts: drafts)
        inlineDrafts.append(contentsOf: added)
        EditorField.insertImageTokens(added.map(\.id), into: textBinding(for: field), selection: selectionBinding(for: field))
    }

    /// Looks the block up by id because it may have moved or been deleted while the image processed.
    private func addGalleryImages(to blockID: UUID, _ added: [ImageDraft]) {
        guard let index = drafts.firstIndex(where: { $0.id == blockID }) else { return }
        drafts[index].images.append(contentsOf: added)
    }

    private func blockRow(_ draft: Binding<BlockDraft>) -> some View {
        let id = draft.wrappedValue.id
        let field = EditorField.block(id)
        return BlockDraftEditor(
            draft: draft,
            selection: selectionBinding(for: field),
            isFocused: EditorField.isFocused($focus, field: field),
            accessory: accessory(for: field),
            imageData: thumbnailData(for:),
            storedImages: storedImages,
            inlineDrafts: inlineDrafts,
            wantsFocus: pendingNewBlockID == id,
            canTakeFocus: { focus == nil || focus == field },
            onFocusRequestDone: { if pendingNewBlockID == id { pendingNewBlockID = nil } },
            onProcessingChange: setBlockProcessing
        ) { addGalleryImages(to: $0, $1) }
    }

    private func setBlockProcessing(_ id: UUID, _ processing: Bool) {
        if processing { processingBlockIDs.insert(id) } else { processingBlockIDs.remove(id) }
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
            ScrollViewReader { proxy in
            Form {
                Section {
                    MarkdownTextView(
                        text: $text,
                        selection: $selection,
                        isFocused: EditorField.isFocused($focus, field: .body),
                        accessibilityLabel: "Thought",
                        imageData: thumbnailData(for:),
                        accessory: accessory(for: .body),
                        undoResetToken: bodyLoadToken,
                        height: $bodyHeight
                    )
                    .frame(height: bodyHeight)
                    .bodyRow()
                    if intake.isProcessing {
                        ImageProcessingIndicator(intake: intake)
                            .bodyRow(vertical: 6)
                    }
                    let thumbnails = inlineThumbnails(in: text, drafts: inlineDrafts, stored: storedImages)
                    if !thumbnails.isEmpty {
                        InlineImageStrip(thumbnails: thumbnails, remove: removeInlineImage)
                            .bodyRow(vertical: 4)
                    }
                    Text(tagsFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tagsFooter)
                        .bodyRow(vertical: 6)
                }

                Section {
                    ForEach($drafts) { blockRow($0) }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        AddBlockMenuItems { addBlock($0) }
                    } label: {
                        Label("Add block", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Blocks")
                } footer: {
                    Text("Add more text or a gallery. Turn on blur to hide an answer until you tap it.")
                }

                Section {
                    LabeledContent(learn ? "First wait" : "Comes back every") {
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
                    Toggle("Learn mode", isOn: $learn)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(learn ? "In Learn mode, this is the first wait. Each Got it makes the next one longer." : "Learn mode asks you to rate the thought when it comes back instead of counting an open as a view.")
                }
            }
            .readableContentMargins()
            .saveErrorAlert(saveErrors)
            .imageIntake(intake, onAdd: addInlineImages)
            .navigationTitle(isNew ? "New thought" : "Edit thought")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { formWidth = $0 }
            .onChange(of: focus) { _, new in
                if let new { activeField = new }
            }
            .task(id: pendingNewBlockID) {
                guard let id = pendingNewBlockID else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                // The block's own row then focuses its field (`BlockDraftEditor.wantsFocus`); keep the id until it has.
                try? await Task.sleep(for: .milliseconds(900))
                if pendingNewBlockID == id { pendingNewBlockID = nil }
            }
            }
        }
        .interactiveDismissDisabled(isDirty)
        .presentationSizing(.page)
        .onAppear {
            EditorShortcuts.shared.open(save: { if canSave { save() } }, cancel: requestCancel)
        }
        .onDisappear { EditorShortcuts.shared.close() }
    }

    private var canSave: Bool { !trimmedText.isEmpty && !isProcessingImages }

    private func requestCancel() {
        if isDirty { isConfirmingDiscard = true } else { dismiss() }
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

    private var prefilledText: String? {
        guard case let .new(prefillTag) = mode, let prefillTag else { return nil }
        return "\n\n#\(prefillTag)"
    }

    /// The body's width is the form's (at most the readable column) less the 16 pt side margins; before
    /// the form has been measured, the width of the foreground window scene.
    private func estimatedBodyHeight() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let width = formWidth > 0 ? formWidth : (scene?.screen.bounds.width ?? 390)
        return MarkdownTextView.estimatedHeight(for: text, width: min(width, ReadableWidth.column) - 32)
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch mode {
        case .new:
            if let prefilledText {
                text = prefilledText
                bodyLoadToken += 1
                bodyHeight = estimatedBodyHeight()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard pendingNewBlockID == nil, focus == nil || focus == .body else { return }
                if prefilledText != nil, text == prefilledText {
                    selection = TextSelection(insertionPoint: text.startIndex)
                }
                focus = .body
            }
        case let .edit(thought):
            text = thought.body
            bodyLoadToken += 1
            bodyHeight = estimatedBodyHeight()
            intervalDays = thought.intervalDays
            learn = thought.intervalMode == .learn
            drafts = BlockDraft.drafts(for: thought)
        }
        openedText = text
        openedDrafts = drafts
        openedIntervalDays = intervalDays
        openedLearn = learn
    }

    /// Dismisses only if the save succeeded, so a failed save keeps the draft on screen.
    /// Uses its own error center because an alert on the root view doesn't show over this sheet.
    private func save() {
        guard saveGate.begin() else { return }
        let store = ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays, saveErrors: saveErrors)
        let saved: Bool
        switch mode {
        case .new:
            let thought = store.create(body: trimmedText, blocks: drafts, images: inlineDrafts, intervalDays: intervalDays, learn: learn, now: .now)
            saved = thought.modelContext != nil
            if saved { onCreated?() }
        case let .edit(thought):
            saveErrors.note = "Some changes may have been saved. Tap Save to finish."
            saved = store.update(thought, body: trimmedText, blocks: drafts, images: inlineDrafts, intervalDays: intervalDays, now: .now)
                && (learn == (thought.intervalMode == .learn) || store.setLearnMode(thought, learn, now: .now))
        }
        if saved {
            dismiss()
        } else {
            saveGate.fail()
        }
    }
}

private extension View {
    /// A row of the body section: edge to edge inside the form's own side margin (about 16 pt), with
    /// no card background or separator, so the text lines up with the screen's readable margin.
    func bodyRow(vertical: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: vertical, leading: 0, bottom: vertical, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Keyboard toolbar that formats Markdown at the cursor or selection.
struct FormatBar: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let intake: ImageIntake
    let onAddBlock: (BlockKind) -> Void

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
                Menu {
                    AddBlockMenuItems(onAdd: onAddBlock)
                } label: {
                    Image(systemName: "plus.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Add block")
            }
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Plain white (black in light mode) icons, not the accent color.
        .tint(.primary)
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

    func apply(_ style: MarkdownFormatter.Inline) {
        commit(MarkdownFormatter.toggle(style, in: text, selection: currentRange))
    }

    func apply(_ prefix: MarkdownFormatter.LinePrefix) {
        commit(MarkdownFormatter.toggle(prefix, in: text, selection: currentRange))
    }

    private func commit(_ edit: MarkdownFormatter.Edit) {
        text = edit.text
        selection = TextSelection(range: edit.selection)
    }

    /// Inserts `#` at the cursor (end of text if there is none) so suggestions appear right away.
    func insertHash() {
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
