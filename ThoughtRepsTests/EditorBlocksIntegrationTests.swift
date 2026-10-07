import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import ThoughtReps

/// The editor with Text blocks, hosted in a real window. Nested in the text view suite, which runs
/// serially, because tests that take the key window and first responder can't overlap.
extension MarkdownTextViewTests {
@MainActor
@Suite("Editor blocks")
struct EditorBlocks {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let isolated = IsolatedDefaults()

    private func pngImage() -> ImageDraft {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        return ImageDraft(processed: ProcessedImage(data: data, thumbnailData: data, width: 80, height: 40))
    }

    private func host<Content: View>(_ content: Content) -> (window: UIWindow, controller: UIHostingController<Content>) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller)
    }

    private func textViews(in view: UIView) -> [StyledTextView] {
        var found: [StyledTextView] = []
        if let styled = view as? StyledTextView { found.append(styled) }
        for sub in view.subviews { found += textViews(in: sub) }
        return found
    }

    /// Waits for `condition`, polling, instead of sleeping a fixed time.
    private func waitUntil(timeout: Double = 4, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeThought(blocks: [BlockDraft], images: [ImageDraft] = []) throws -> (ModelContainer, Thought) {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
        let thought = store.create(body: "Body **text**", blocks: blocks, images: images, now: now)
        return (container, thought)
    }

    /// A text view and coordinator wired to `focus` the way `EditorView` wires a field.
    private func makeField(
        _ field: EditorField, text: String, focus: Binding<EditorField?>, in window: UIWindow, y: CGFloat = 0
    ) -> (view: StyledTextView, coordinator: MarkdownTextView.Coordinator, representable: MarkdownTextView, state: FieldState) {
        let state = FieldState(text: text)
        let representable = MarkdownTextView(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            isFocused: EditorField.isFocused(focus, field: field),
            accessibilityLabel: "Field",
            imageData: { _ in nil },
            accessory: AnyView(EmptyView()),
            undoResetToken: 0,
            height: .constant(100)
        )
        let view = StyledTextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: y, width: 390, height: 200)
        window.addSubview(view)
        let coordinator = representable.makeCoordinator()
        coordinator.attach(to: view, accessory: AnyView(EmptyView()))
        coordinator.update(representable)
        return (view, coordinator, representable, state)
    }

    @Test func bodyAndEveryTextBlockAreLiveStyledFields() async throws {
        let (container, thought) = try makeThought(blocks: [
            BlockDraft(title: "A", content: "intro\nfirst **block**\nlast"),
            BlockDraft(content: "second"),
        ])
        let (window, _) = host(EditorView(mode: .edit(thought)).modelContainer(container))
        defer { window.isHidden = true }
        try await waitUntil { textViews(in: window).count == 3 }
        let fields = textViews(in: window)
        #expect(fields.count == 3)
        #expect(Set(fields.map { $0.text ?? "" }) == ["Body **text**", "intro\nfirst **block**\nlast", "second"])
        #expect(fields.allSatisfy { !$0.isScrollEnabled })
        let block = fields.first { $0.text == "intro\nfirst **block**\nlast" }!
        let font = block.textStorage.attribute(.font, at: 12, effectiveRange: nil) as? UIFont
        #expect((font?.pointSize ?? 99) < 1, "syntax of a block that isn't being edited is hidden")
    }

    @Test func emptyTextBlockShowsItsPlaceholder() async throws {
        let (container, thought) = try makeThought(blocks: [BlockDraft(content: "x")])
        let (window, _) = host(EditorView(mode: .edit(thought)).modelContainer(container))
        defer { window.isHidden = true }
        try await waitUntil { textViews(in: window).count == 2 }
        let block = textViews(in: window).first { $0.text == "x" }!
        let label = block.subviews.compactMap { $0 as? UILabel }.first
        #expect(label?.text == "Markdown text")
        #expect(label?.isHidden == true)
    }

    @Test func blockThumbnailsResolveFromTheThoughtsOwnImages() async throws {
        let image = pngImage()
        let token = ImageToken.token(for: image.id)
        let (container, thought) = try makeThought(blocks: [BlockDraft(content: "Look\n\n\(token)\n\nthere")], images: [image])
        let (window, _) = host(EditorView(mode: .edit(thought)).modelContainer(container))
        defer { window.isHidden = true }
        try await waitUntil { textViews(in: window).count == 2 }
        let block = textViews(in: window).first { ($0.text ?? "").contains("Look") }!
        let tokenStart = (block.text! as NSString).range(of: token).location
        func tokenFont(_ view: StyledTextView, at offset: Int) -> CGFloat {
            (view.textStorage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)?.pointSize ?? 99
        }
        try await waitUntil { tokenFont(block, at: tokenStart + 3) < 1 }
        #expect(tokenFont(block, at: tokenStart + 3) < 1, "the token is replaced by a thumbnail")

        let stranger = ImageToken.token(for: UUID())
        let (container2, thought2) = try makeThought(blocks: [BlockDraft(content: "Look\n\n\(stranger)")])
        let (window2, _) = host(EditorView(mode: .edit(thought2)).modelContainer(container2))
        defer { window2.isHidden = true }
        try await waitUntil { textViews(in: window2).count == 2 }
        let block2 = textViews(in: window2).first { ($0.text ?? "").contains("Look") }!
        let start2 = (block2.text! as NSString).range(of: stranger).location
        #expect(tokenFont(block2, at: start2 + 3) > 5, "an image the thought doesn't own stays as text")
    }

    @Test func manyTextBlocksDoNotMultiplyTheWorkOfAKeystroke() async throws {
        func keystroke(blocks: Int) async throws -> (updates: Int, median: Duration) {
            let drafts = (0..<blocks).map { BlockDraft(content: "Block \($0) with **bold** and\n- a list\n- [ ] a task") }
            let (container, thought) = try makeThought(blocks: drafts)
            let (window, _) = host(EditorView(mode: .edit(thought)).modelContainer(container))
            defer { window.isHidden = true }
            try await waitUntil { textViews(in: window).count > blocks }
            let body = textViews(in: window).first { $0.text == "Body **text**" }!
            body.becomeFirstResponder()
            body.selectedRange = NSRange(location: 4, length: 0)
            try await Task.sleep(for: .milliseconds(100))
            let fields = textViews(in: window).count
            let before = MarkdownTextView.Coordinator.updateCount
            var samples: [Duration] = []
            for _ in 0..<10 {
                samples.append(ContinuousClock().measure {
                    body.insertText("x")
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                })
            }
            // Each keystroke re-renders every field once or twice, never more per field.
            #expect(MarkdownTextView.Coordinator.updateCount - before <= 10 * 3 * fields)
            return (MarkdownTextView.Coordinator.updateCount - before, samples.sorted()[samples.count / 2])
        }
        let none = try await keystroke(blocks: 0)
        let many = try await keystroke(blocks: 20)
        #expect(many.updates <= none.updates * 21 + 10, "updates: none \(none.updates), 20 blocks \(many.updates)")
        #expect(many.median < none.median + .milliseconds(200), "no blocks \(none.median), 20 blocks \(many.median)")
    }

    @Test func aNewlyAddedTextBlockTakesFocusOnItsMarkdownField() async throws {
        final class Model { var focused = false; var done = false }
        let model = Model()
        struct Row: View {
            @State var draft = BlockDraft(content: "")
            @State var selection: TextSelection?
            @State var focused = false
            let model: Model
            var body: some View {
                BlockDraftEditor(
                    draft: $draft,
                    selection: $selection,
                    isFocused: $focused,
                    accessory: AnyView(EmptyView()),
                    imageData: { _ in nil },
                    storedImages: [:],
                    inlineDrafts: [],
                    wantsFocus: true,
                    onFocusRequestDone: { model.done = true }
                ) { _, _ in }
                .onChange(of: focused) { model.focused = focused }
            }
        }
        let (window, _) = host(List { Row(model: model) })
        defer { window.isHidden = true }
        try await waitUntil { model.done }
        let field = textViews(in: window).first
        #expect(model.focused)
        #expect(model.done)
        #expect(field?.isFirstResponder == true)
    }

    @Test func aFocusRequestDoesNotOverrideAFieldTheUserFocusedMeanwhile() async throws {
        final class Model { var focused = false; var done = false }
        let model = Model()
        struct Row: View {
            @State var draft = BlockDraft(content: "")
            @State var selection: TextSelection?
            @State var focused = false
            let model: Model
            var body: some View {
                BlockDraftEditor(
                    draft: $draft,
                    selection: $selection,
                    isFocused: $focused,
                    accessory: AnyView(EmptyView()),
                    imageData: { _ in nil },
                    storedImages: [:],
                    inlineDrafts: [],
                    wantsFocus: true,
                    canTakeFocus: { false },
                    onFocusRequestDone: { model.done = true }
                ) { _, _ in }
                .onChange(of: focused) { model.focused = focused }
            }
        }
        let (window, _) = host(List { Row(model: model) })
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(900))
        #expect(!model.focused)
        #expect(textViews(in: window).first?.isFirstResponder != true)
    }

    @Test func focusStaysInStepWithTheFirstResponder() async throws {
        final class Model { var focus: EditorField? }
        let model = Model()
        let focus = Binding(get: { model.focus }, set: { model.focus = $0 })
        let blockID = UUID()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()

        let body = makeField(.body, text: "body", focus: focus, in: window)
        let block = makeField(.block(blockID), text: "block", focus: focus, in: window, y: 300)

        body.view.becomeFirstResponder()
        #expect(model.focus == .body)
        block.view.becomeFirstResponder()
        #expect(model.focus == .block(blockID))
        #expect(!body.view.isFirstResponder)
        block.view.resignFirstResponder()
        #expect(model.focus == nil)

        model.focus = .body
        body.coordinator.update(body.representable)
        try await waitUntil(timeout: 1) { body.view.isFirstResponder }
        #expect(body.view.isFirstResponder)
    }

    @Test func aRebuiltFieldDoesNotRetakeTheKeyboardFromAStaleFocus() async throws {
        final class Model { var focus: EditorField? }
        let model = Model()
        let focus = Binding(get: { model.focus }, set: { model.focus = $0 })
        let blockID = UUID()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()

        let first = makeField(.block(blockID), text: "block", focus: focus, in: window)
        first.view.becomeFirstResponder()
        #expect(model.focus == .block(blockID))

        MarkdownTextView.dismantleUIView(first.view, coordinator: first.coordinator)
        first.view.removeFromSuperview()
        try await waitUntil(timeout: 1) { model.focus == nil }
        #expect(model.focus == nil)

        model.focus = .block(blockID)
        let rebuilt = makeField(.block(blockID), text: "block", focus: focus, in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!rebuilt.view.isFirstResponder)
    }

    @Test func aFieldCreatedWithAMatchingFocusStaysUnfocusedButTakesLaterRequests() async throws {
        final class Model { var focus: EditorField? }
        let model = Model()
        let focus = Binding(get: { model.focus }, set: { model.focus = $0 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let field = makeField(.body, text: "x", focus: focus, in: window)
        field.view.resignFirstResponder()
        model.focus = .body
        field.coordinator.update(field.representable)
        try await waitUntil(timeout: 1) { field.view.isFirstResponder }
        #expect(field.view.isFirstResponder)
    }

    @Test func aNewThoughtWithAPrefilledTagStartsWithTheCaretAtTheStart() async throws {
        final class Model { var focus: EditorField? }
        let model = Model()
        let focus = Binding(get: { model.focus }, set: { model.focus = $0 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let field = makeField(.body, text: "", focus: focus, in: window)

        // What EditorView.load does: the text and the start-of-text selection are set, then focus is requested.
        let prefilled = "\n\n#tag"
        field.state.text = prefilled
        field.state.selection = TextSelection(insertionPoint: prefilled.startIndex)
        model.focus = .body
        field.coordinator.update(field.representable)
        try await waitUntil(timeout: 1) { field.view.isFirstResponder }
        #expect(field.view.isFirstResponder)
        #expect(field.view.selectedRange == NSRange(location: 0, length: 0))
    }

    // MARK: Actions on the focused block's bindings

    @Test func formatBarActionsEditTheFieldTheyAreBoundTo() {
        let body = FieldState(text: "body text")
        let block = FieldState(text: "answer")
        block.selection = TextSelection(range: block.text.startIndex..<block.text.endIndex)
        let bar = FormatBar(
            text: Binding(get: { block.text }, set: { block.text = $0 }),
            selection: Binding(get: { block.selection }, set: { block.selection = $0 }),
            intake: ImageIntake(),
            onAddBlock: { _ in }
        )
        bar.apply(.bold)
        #expect(block.text == "**answer**")
        bar.apply(.bullet)
        #expect(block.text == "- **answer**")
        bar.insertHash()
        #expect(block.text.contains("#"))
        #expect(body.text == "body text")
        #expect(body.selection == nil)
        if case let .selection(range)? = block.selection?.indices {
            #expect(range.lowerBound <= block.text.endIndex)
        } else {
            Issue.record("the block's selection should have been updated")
        }
    }

    @Test func aTagSuggestionCompletesTheTagInTheBlockItIsBoundTo() {
        let body = FieldState(text: "body #sw")
        let block = FieldState(text: "answer #sw")
        block.selection = TextSelection(insertionPoint: block.text.endIndex)
        let token = TagSuggester.activeToken(in: block.text, cursor: block.text.endIndex)!
        EditorField.applyTag(
            TagSuggester.Candidate(key: "swift", display: "Swift", count: 2),
            replacing: token.range,
            in: Binding(get: { block.text }, set: { block.text = $0 }),
            selection: Binding(get: { block.selection }, set: { block.selection = $0 })
        )
        #expect(block.text.hasPrefix("answer #Swift"))
        #expect(body.text == "body #sw")
    }

    @Test func insertedImagesGoToTheFocusedBlockOrTheBodyWhenItIsGone() {
        let kept = BlockDraft(content: "block")
        let gone = BlockDraft(content: "gone")
        let drafts = [kept]
        #expect(EditorField.resolve(.block(kept.id), drafts: drafts) == .block(kept.id))
        #expect(EditorField.resolve(.block(gone.id), drafts: drafts) == .body)
        #expect(EditorField.resolve(.body, drafts: drafts) == .body)

        let body = FieldState(text: "body")
        let block = FieldState(text: "block")
        block.selection = TextSelection(insertionPoint: block.text.endIndex)
        let id = UUID()
        EditorField.insertImageTokens(
            [id],
            into: Binding(get: { block.text }, set: { block.text = $0 }),
            selection: Binding(get: { block.selection }, set: { block.selection = $0 })
        )
        #expect(block.text.contains(ImageToken.token(for: id)))
        #expect(body.text == "body")
    }

    @Test func returnInsideABlockContinuesItsList() {
        let old = ["body", "- item", "other"]
        let new = ["body", "- item\n", "other"]
        guard let index = EditorField.changedIndex(from: old, to: new) else {
            Issue.record("one text changed")
            return
        }
        #expect(index == 1)
        let continued = MarkdownFormatter.continueList(from: old[index], to: new[index], cursor: new[index].endIndex)
        #expect(continued?.text == "- item\n- ")
    }
}
}

@MainActor
private final class FieldState {
    var text: String
    var selection: TextSelection?

    init(text: String) { self.text = text }
}
