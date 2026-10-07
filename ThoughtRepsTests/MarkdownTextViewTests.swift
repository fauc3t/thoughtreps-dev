import SwiftUI
import Testing
import UIKit
@testable import ThoughtReps

@MainActor
@Suite("MarkdownTextView", .serialized)
struct MarkdownTextViewTests {
    /// Owns the bindings the way `EditorView`'s state does.
    final class Model {
        var text: String
        var selection: TextSelection?
        var isFocused = false
        var height: CGFloat = 220

        init(_ text: String) { self.text = text }
    }

    @MainActor
    struct Harness {
        let model: Model
        let view: StyledTextView
        let coordinator: MarkdownTextView.Coordinator
        let window: UIWindow
        let id: UUID

        func representable() -> MarkdownTextView {
            let model = model
            let imageData = png
            let id = id
            return MarkdownTextView(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                selection: Binding(get: { model.selection }, set: { model.selection = $0 }),
                isFocused: Binding(get: { model.isFocused }, set: { model.isFocused = $0 }),
                accessibilityLabel: "Thought",
                imageData: { $0 == id ? imageData : nil },
                accessory: AnyView(EmptyView()),
                undoResetToken: 0,
                height: Binding(get: { model.height }, set: { model.height = $0 })
            )
        }

        func refresh() { coordinator.update(representable()) }

        /// One undo group per call, since a test never spins the run loop that would split them.
        func grouped(_ body: () -> Void) {
            let manager = view.undoManager!
            manager.groupsByEvent = false
            manager.beginUndoGrouping()
            body()
            manager.endUndoGrouping()
        }
    }

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    private func makeHarness(_ text: String, id: UUID = UUID()) -> Harness {
        let model = Model(text)
        let view = StyledTextView(usingTextLayoutManager: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        let coordinator = MarkdownTextView.Coordinator(
            MarkdownTextView(
                text: .constant(text), selection: .constant(nil), isFocused: .constant(false),
                accessibilityLabel: "Thought", imageData: { _ in nil }, accessory: AnyView(EmptyView()), undoResetToken: 0, height: .constant(MarkdownTextView.minHeight)
            )
        )
        let harness = Harness(model: model, view: view, coordinator: coordinator, window: window, id: id)
        coordinator.attach(to: view, accessory: AnyView(EmptyView()))
        harness.refresh()
        view.undoManager?.removeAllActions()
        view.becomeFirstResponder()
        return harness
    }

    private func font(_ h: Harness, at offset: Int) -> UIFont? {
        h.view.textStorage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
    }

    private func color(_ h: Harness, at offset: Int) -> UIColor? {
        h.view.textStorage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
    }

    /// Hosted in SwiftUI the way the editor hosts it, a long line wraps at the offered width instead
    /// of widening the view to the line (which left the editor scrolled sideways).
    @Test func longLineWrapsAtTheOfferedWidth() throws {
        let line = String(repeating: "a long line of words ", count: 40)
        let host = UIHostingController(rootView: MarkdownTextView(
            text: .constant(line), selection: .constant(nil), isFocused: .constant(false),
            accessibilityLabel: "Thought", imageData: { _ in nil }, accessory: AnyView(EmptyView()),
            undoResetToken: 0, height: .constant(MarkdownTextView.minHeight)
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let view = try #require(Self.find(StyledTextView.self, in: host.view))
        #expect(view.frame.width <= 390)
        #expect(view.contentSize.width <= 390)
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    @Test func textStaysExactMarkdownAndGetsStyled() {
        let source = "# Title\n\nSome **bold** and #tag"
        let h = makeHarness(source)
        h.view.selectedRange = NSRange(location: 0, length: 0)
        #expect(h.view.text == source)
        #expect(font(h, at: 2)!.pointSize > font(h, at: 10)!.pointSize)
        #expect(font(h, at: 17)!.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(color(h, at: 0) == .secondaryLabel)
        #expect(color(h, at: 14) == .clear)
        h.view.selectedRange = NSRange(location: 20, length: 0)
        #expect(color(h, at: 14) == .secondaryLabel)
        #expect(color(h, at: 28) == .tintColor)
        #expect(color(h, at: 10) == .label)
    }

    @Test func typingRestylesTheEditedLine() {
        let h = makeHarness("plain\n\nsecond")
        h.view.selectedRange = NSRange(location: 5, length: 0)
        h.view.insertText(" **b**")
        #expect(h.model.text == "plain **b**\n\nsecond")
        #expect(color(h, at: 6) == .secondaryLabel)
        #expect(color(h, at: 8) == .label)
    }

    @Test func externalChangeIsAppliedAndUndoable() {
        let h = makeHarness("hello")
        h.view.selectedRange = NSRange(location: 5, length: 0)
        h.model.text = "hello **world**"
        h.model.selection = TextSelection(insertionPoint: h.model.text.endIndex)
        h.refresh()
        #expect(h.view.text == "hello **world**")
        #expect(h.view.selectedRange == NSRange(location: 15, length: 0))
        #expect(color(h, at: 6) == .secondaryLabel)

        h.view.undoManager?.undo()
        #expect(h.view.text == "hello")
        #expect(h.model.text == "hello")
    }

    @Test func fenceTypedAtTheEndStylesTheRest() {
        let h = makeHarness("intro\n``\ncode **x**\nmore")
        let bold = font(h, at: 18)!
        h.view.selectedRange = NSRange(location: 8, length: 0)
        h.view.insertText("`")
        #expect(font(h, at: 19)!.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == false)
    }

    @Test func imageTokenIsOneUnit() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let source = "before\n\n\(token)\n\nafter"
        let h = makeHarness(source, id: id)
        let start = 8
        let end = start + token.utf16.count

        #expect(h.coordinator.displayedImageCount == 1)
        #expect(color(h, at: start + 5) == .clear)

        h.view.selectedRange = NSRange(location: start + 10, length: 0)
        #expect(h.view.selectedRange.location == start || h.view.selectedRange.location == end)

        h.view.selectedRange = NSRange(location: end, length: 0)
        h.view.deleteBackward()
        #expect(h.model.text == "before\n\n\n\nafter")
        #expect(h.coordinator.displayedImageCount == 0)
    }

    @Test func partialSelectionOfATokenGrowsToCoverIt() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let h = makeHarness("a\n\n\(token)\n\nb", id: id)
        let start = 3
        h.view.selectedRange = NSRange(location: start - 2, length: 10)
        #expect(h.view.selectedRange.location == start - 2)
        #expect(h.view.selectedRange.upperBound == start + token.utf16.count)
    }

    @Test func insertedTokenShowsAThumbnailBelowTheTextAbove() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let h = makeHarness("first line", id: id)
        let inserted = ImageToken.inserting(id, into: h.model.text, at: h.model.text.endIndex)
        h.model.text = inserted.text
        h.model.selection = TextSelection(insertionPoint: inserted.cursor)
        h.refresh()
        #expect(h.view.text == "first line\n\n\(token)\n\n")
        #expect(h.coordinator.displayedImageCount == 1)

        h.view.layoutIfNeeded()
        let thumbnails = h.view.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden && $0.image != nil }
        #expect(thumbnails.count == 1)
        let frame = thumbnails[0].frame
        #expect(frame.height == 160 && frame.width == 320)
        #expect(frame.minY > 20)
        #expect(frame.minX == 0)

        let end = NSRange(location: 12 + token.utf16.count, length: 0)
        h.view.selectedRange = end
        let caret = h.view.caretRect(for: h.view.selectedTextRange!.end)
        #expect(abs(caret.minX - frame.maxX) < 12)
    }

    @Test func copyKeepsTheTokenText() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let h = makeHarness("a\n\n\(token)\n\nb", id: id)
        h.view.selectedRange = NSRange(location: 3, length: token.utf16.count)
        h.view.copy(nil)
        #expect(UIPasteboard.general.string == token)
    }

    @Test func tokenWithUnknownImageStaysVisibleAsFadedText() {
        let token = ImageToken.token(for: UUID())
        let h = makeHarness("a\n\n\(token)\n\nb")
        #expect(h.coordinator.displayedImageCount == 0)
        #expect(color(h, at: 5) == .secondaryLabel)
    }

    private func visibleThumbnails(_ h: Harness) -> [UIImageView] {
        h.view.layoutIfNeeded()
        return h.view.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden && $0.image != nil }
    }

    @Test func nativeUndoAndRedoOfTypedText() {
        let h = makeHarness("plain")
        h.view.selectedRange = NSRange(location: 5, length: 0)
        h.grouped { h.view.insertText(" **b**") }
        #expect(color(h, at: 6) == .secondaryLabel)

        h.view.undoManager?.undo()
        #expect(h.view.text == "plain")
        #expect(h.model.text == "plain")
        #expect(color(h, at: 2) == .label)

        h.view.undoManager?.redo()
        #expect(h.view.text == "plain **b**")
        #expect(h.model.text == "plain **b**")
        #expect(color(h, at: 6) == .secondaryLabel)
        #expect(color(h, at: 8) == .label)
    }

    @Test func undoAndRedoOfATokenDeleteKeepThumbnailStateInSync() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let source = "a\n\n\(token)\n\nb"
        let h = makeHarness(source, id: id)
        let end = 3 + token.utf16.count
        h.view.selectedRange = NSRange(location: end, length: 0)
        h.grouped { h.view.deleteBackward() }
        #expect(h.coordinator.displayedImageCount == 0)

        h.view.undoManager?.undo()
        #expect(h.view.text == source)
        #expect(h.coordinator.displayedImageCount == 1)
        #expect(visibleThumbnails(h).count == 1)
        h.view.selectedRange = NSRange(location: 10, length: 0)
        #expect([3, end].contains(h.view.selectedRange.location))

        h.view.undoManager?.redo()
        #expect(h.view.text == "a\n\n\n\nb")
        #expect(h.coordinator.displayedImageCount == 0)
        #expect(visibleThumbnails(h).isEmpty)
    }

    @Test func undoAndRedoOfATokenInsertKeepThumbnailStateInSync() {
        let id = UUID()
        let h = makeHarness("first", id: id)
        let inserted = ImageToken.inserting(id, into: "first", at: h.model.text.endIndex)
        h.grouped {
            h.model.text = inserted.text
            h.model.selection = TextSelection(insertionPoint: inserted.cursor)
            h.refresh()
        }
        #expect(h.coordinator.displayedImageCount == 1)

        h.view.undoManager?.undo()
        #expect(h.view.text == "first")
        #expect(h.model.text == "first")
        #expect(h.coordinator.displayedImageCount == 0)
        #expect(visibleThumbnails(h).isEmpty)

        h.view.undoManager?.redo()
        #expect(h.view.text == inserted.text)
        #expect(h.coordinator.displayedImageCount == 1)
        #expect(visibleThumbnails(h).count == 1)
    }

    @Test func externalEditIntoAnEmptyBodyIsUndoable() {
        let h = makeHarness("")
        h.grouped {
            h.model.text = "**x**"
            h.refresh()
        }
        h.view.undoManager?.undo()
        #expect(h.view.text == "")
        #expect(h.model.text == "")
    }

    @Test func markedTextIsNotRestyledUntilCommitted() {
        let h = makeHarness("x ")
        h.view.selectedRange = NSRange(location: 2, length: 0)
        h.view.setMarkedText("**ab**", selectedRange: NSRange(location: 6, length: 0))
        #expect(h.view.markedTextRange != nil)
        #expect(h.view.text == "x **ab**")
        #expect(color(h, at: 2) != .secondaryLabel)

        h.view.unmarkText()
        #expect(h.view.markedTextRange == nil)
        #expect(color(h, at: 2) == .secondaryLabel)
        #expect(color(h, at: 4) == .label)
        #expect(h.model.text == "x **ab**")
    }

    @Test func surrogatePairsSurviveExternalReplacement() {
        let h = makeHarness("a😀b")
        h.grouped {
            h.model.text = "a😁b"
            h.refresh()
        }
        #expect(h.view.text == "a😁b")
        h.grouped {
            h.model.text = "a😁😀b"
            h.refresh()
        }
        #expect(h.view.text == "a😁😀b")
        h.grouped {
            h.model.text = "a😀b"
            h.refresh()
        }
        #expect(h.view.text == "a😀b")
        h.view.undoManager?.undo()
        #expect(h.view.text == "a😁😀b")
        h.view.undoManager?.undo()
        #expect(h.view.text == "a😁b")
        h.view.undoManager?.undo()
        #expect(h.view.text == "a😀b")
    }

    @Test func combiningMarksSurviveExternalReplacement() {
        let h = makeHarness("e\u{301}x")
        h.model.text = "e\u{301}y"
        h.refresh()
        #expect(h.view.text == "e\u{301}y")
        h.model.text = "e\u{300}y"
        h.refresh()
        #expect(h.view.text == "e\u{300}y")
    }

    @Test func selectionRoundTripsWithEmojiAndCombiningMarks() {
        let h = makeHarness("😀e\u{301}z")
        h.model.selection = TextSelection(insertionPoint: String.Index(utf16Offset: 4, in: h.model.text))
        h.refresh()
        #expect(h.view.selectedRange == NSRange(location: 4, length: 0))

        h.view.insertText("!")
        #expect(h.model.text == "😀e\u{301}!z")
        guard case let .selection(range)? = h.model.selection?.indices else {
            Issue.record("no selection")
            return
        }
        #expect(range.lowerBound.utf16Offset(in: h.model.text) == 5)
        h.refresh()
        #expect(h.view.selectedRange == NSRange(location: 5, length: 0))
    }

    @Test func bindingLoopSettlesWithoutExtraUndoEntriesOrDrift() {
        let h = makeHarness("hello")
        h.view.selectedRange = NSRange(location: 5, length: 0)
        h.grouped { h.view.insertText("x") }
        let selection = h.view.selectedRange
        for _ in 0..<3 { h.refresh() }
        #expect(h.view.selectedRange == selection)
        #expect(h.view.text == "hellox")

        h.view.undoManager?.undo()
        #expect(h.view.text == "hello")
        #expect(h.view.undoManager?.canUndo == false)
    }

    @Test func cutRemovesAndCopiesPlainText() {
        let h = makeHarness("one **two** three")
        h.view.selectedRange = NSRange(location: 4, length: 7)
        h.view.cut(nil)
        #expect(UIPasteboard.general.string == "**two**")
        #expect(h.view.text == "one  three")
        #expect(h.model.text == "one  three")
    }

    @Test func forwardDeleteOverATokenRemovesItWhole() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let h = makeHarness("a\n\n\(token)\n\nb", id: id)
        let allowed = h.coordinator.textView(h.view, shouldChangeTextIn: NSRange(location: 3, length: 1), replacementText: "")
        #expect(!allowed)
        #expect(h.model.text == "a\n\n\n\nb")
        #expect(h.coordinator.displayedImageCount == 0)
    }

    @Test func typingAttributesStayAtBodyStyleAfterAHeading() {
        let h = makeHarness("# Title")
        h.view.selectedRange = NSRange(location: 7, length: 0)
        h.view.insertText("s")
        let font = h.view.typingAttributes[.font] as? UIFont
        #expect(font?.pointSize == UIFont.preferredFont(forTextStyle: .body).pointSize)
    }

    @Test func resignsWhenFocusIsTakenAway() async throws {
        let h = makeHarness("x")
        #expect(h.view.isFirstResponder)
        #expect(h.model.isFocused)
        h.model.isFocused = false
        h.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!h.view.isFirstResponder)
    }

    @Test func unannouncedChangeInALargeBodyRestylesEverythingWithinBounds() {
        let paragraph = "Some *emphasis*, **bold**, `code`, [link](https://x.com) and #tag in a line of prose.\n"
        let h = makeHarness(String(repeating: paragraph, count: 600))
        h.view.selectedRange = NSRange(location: 30_000, length: 0)
        let started = ContinuousClock.now
        h.view.insertText("x")
        #expect(ContinuousClock.now - started < .milliseconds(400))
    }

    private func caretX(_ h: Harness, at offset: Int) -> CGFloat {
        h.view.layoutIfNeeded()
        return h.view.caretRect(for: h.view.position(from: h.view.beginningOfDocument, offset: offset)!).minX
    }

    private func isHidden(_ h: Harness, at offset: Int) -> Bool {
        let font = h.view.textStorage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
        return (font?.pointSize ?? 99) < 1 && color(h, at: offset) == .clear
    }

    private func glyphOverlays(_ h: Harness) -> [UIImageView] {
        h.view.layoutIfNeeded()
        return h.view.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden && $0.image != nil && $0.contentMode == .center }
    }

    // MARK: Hidden syntax

    @Test func syntaxIsHiddenOffTheCursorLineAndFadedOnIt() {
        let h = makeHarness("**a** b\nsecond **c** line")
        h.view.selectedRange = NSRange(location: 12, length: 0)
        #expect(isHidden(h, at: 0) && isHidden(h, at: 1) && isHidden(h, at: 3) && isHidden(h, at: 4))
        #expect(!isHidden(h, at: 2))
        #expect(color(h, at: 16) == .secondaryLabel)
        #expect(!isHidden(h, at: 16))
        #expect(h.view.text == "**a** b\nsecond **c** line")
    }

    @Test func hiddenSyntaxTakesNoWidth() {
        let h = makeHarness("x **bold** y\n[link](https://example.com/very/long/path) z")
        h.view.selectedRange = NSRange(location: 30, length: 0)
        #expect(abs(caretX(h, at: 2) - caretX(h, at: 4)) < 1)
        #expect(abs(caretX(h, at: 8) - caretX(h, at: 10)) < 1)
        h.view.selectedRange = NSRange(location: 3, length: 0)
        #expect(caretX(h, at: 4) > caretX(h, at: 2) + 2)
    }

    @Test func hiddenLinkShowsOnlyItsText() {
        let h = makeHarness("see [the docs](https://example.com) now\nsecond line")
        h.view.selectedRange = NSRange(location: 45, length: 0)
        let ns = h.view.text as NSString
        let open = ns.range(of: "[").location
        #expect(isHidden(h, at: open))
        let closing = ns.range(of: "](https://example.com)")
        #expect((closing.location..<closing.upperBound).allSatisfy { isHidden(h, at: $0) })
        #expect(color(h, at: open + 1) == .tintColor)
    }

    @Test func headingAndQuoteMarkersHideWithTheirSpace() {
        let h = makeHarness("# Title\n> quoted\nplain")
        h.view.selectedRange = NSRange(location: 20, length: 0)
        #expect(isHidden(h, at: 0) && isHidden(h, at: 1))
        #expect(!isHidden(h, at: 2))
        #expect(isHidden(h, at: 8) && isHidden(h, at: 9))
        #expect(!isHidden(h, at: 10))
    }

    @Test func movingTheSelectionRestylesOnlyTheOldAndNewLines() {
        let lines = (0..<40).map { "line **\($0)** text" }
        let text = lines.joined(separator: "\n")
        let h = makeHarness(text)
        let ns = text as NSString
        let first = ns.lineRange(for: NSRange(location: 2, length: 0))
        h.view.selectedRange = NSRange(location: 2, length: 0)
        #expect(h.coordinator.revealed == first)
        let target = ns.lineRange(for: NSRange(location: ns.length - 3, length: 0))
        h.view.selectedRange = NSRange(location: ns.length - 3, length: 0)

        #expect(h.coordinator.revealed == target)
        let styled = Array(h.coordinator.recentlyStyled.suffix(2))
        #expect(styled == [first, target])
        #expect(isHidden(h, at: 5))
        #expect(!isHidden(h, at: target.location + 5))
        #expect(color(h, at: target.location + 5) == .secondaryLabel)
    }

    @Test func caretNeverRestsInsideHiddenSyntax() {
        let h = makeHarness("x\n**bold** y")
        h.view.selectedRange = NSRange(location: 0, length: 0)
        h.view.selectedRange = NSRange(location: 3, length: 0)
        #expect([2, 4].contains(h.view.selectedRange.location))
        #expect(h.coordinator.revealed == NSRange(location: 2, length: 10))
        #expect(color(h, at: 2) == .secondaryLabel)
    }

    @Test func multiLineSelectionRevealsEveryLine() {
        let h = makeHarness("**a** one\n**b** two\n**c** three")
        h.view.selectedRange = NSRange(location: 3, length: 14)
        #expect(!isHidden(h, at: 0))
        #expect(!isHidden(h, at: 10))
        #expect(isHidden(h, at: 20))
        h.view.selectedRange = NSRange(location: 0, length: (h.view.text as NSString).length)
        for offset in [0, 1, 10, 11, 20, 21] { #expect(!isHidden(h, at: offset)) }
    }

    @Test func copyAndCutKeepTheFullMarkdownWhileSyntaxIsHidden() {
        let h = makeHarness("**a** [l](u)\nsecond")
        h.view.selectedRange = NSRange(location: 15, length: 0)
        #expect(isHidden(h, at: 0))
        h.view.selectedRange = NSRange(location: 0, length: 12)
        h.view.copy(nil)
        #expect(UIPasteboard.general.string == "**a** [l](u)")
        h.view.cut(nil)
        #expect(h.model.text == "\nsecond")
    }

    @Test func fencesCollapseOutsideTheBlockAndShowWithinIt() {
        let h = makeHarness("intro\n```swift\nlet x = 1\n```\noutro")
        h.view.selectedRange = NSRange(location: 2, length: 0)
        #expect(isHidden(h, at: 6) && isHidden(h, at: 14))
        #expect(!isHidden(h, at: 16))
        let code = h.view.textStorage.attribute(.backgroundColor, at: 16, effectiveRange: nil) as? UIColor
        #expect(code == .secondarySystemFill)
        h.view.selectedRange = NSRange(location: 18, length: 0)
        #expect(!isHidden(h, at: 6) && !isHidden(h, at: 14))
        #expect(color(h, at: 6) == .secondaryLabel)
    }

    // MARK: Lists

    @Test func bulletGlyphsFollowTheNestingLevel() {
        let h = makeHarness("- a\n  - b\n    - c\n1. d")
        h.view.selectedRange = NSRange(location: 0, length: 0)
        let markers = h.coordinator.displayedMarkers
        #expect(markers.map(\.prefix.level) == [1, 2, 3, 1])
        #expect(markers.map { $0.glyph != nil } == [true, true, true, false])
        let glyphs = markers.compactMap(\.glyph)
        #expect(glyphs[0] !== glyphs[1] && glyphs[1] !== glyphs[2])
        #expect(markers[0].tint == .secondaryLabel)
        #expect(isHidden(h, at: 0))
        #expect(isHidden(h, at: 1))
        let numbered = (h.view.text as NSString).range(of: "1.").location
        #expect(color(h, at: numbered) == .secondaryLabel)
        #expect(!isHidden(h, at: numbered))
        #expect(glyphOverlays(h).count == 3)
    }

    @Test func glyphsShowOnTheCursorLineToo() {
        let h = makeHarness("- a\n- [ ] b")
        h.view.selectedRange = NSRange(location: 5, length: 0)
        #expect(h.coordinator.displayedMarkers.count == 2)
        #expect(isHidden(h, at: 0))
        #expect(isHidden(h, at: 4))
        #expect(glyphOverlays(h).count == 2)
    }

    @Test func wrappedListLinesHangUnderTheItemText() {
        let h = makeHarness("  - " + String(repeating: "word ", count: 40))
        let style = h.view.textStorage.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 20)
        #expect(style?.firstLineHeadIndent == 0)
    }

    @Test func checkboxTapTogglesTheTextAndIsUndoable() {
        let h = makeHarness("- [ ] task\nnext")
        h.view.selectedRange = NSRange(location: 12, length: 0)
        let box = glyphOverlays(h)
        guard box.count == 1 else {
            Issue.record("expected one checkbox overlay, found \(box.count)")
            return
        }
        let point = CGPoint(x: box[0].frame.midX, y: box[0].frame.midY)
        let selection = h.view.selectedRange
        h.view.resignFirstResponder()

        h.grouped { #expect(h.coordinator.toggleCheckbox(at: point)) }
        #expect(h.model.text == "- [x] task\nnext")
        #expect(h.view.selectedRange == selection)
        #expect(!h.view.isFirstResponder)
        #expect(h.coordinator.displayedMarkers.first?.prefix.kind == .task(checked: true))

        h.view.undoManager?.undo()
        #expect(h.model.text == "- [ ] task\nnext")
        #expect(h.coordinator.displayedMarkers.first?.prefix.kind == .task(checked: false))
        h.view.undoManager?.redo()
        #expect(h.model.text == "- [x] task\nnext")

        #expect(!h.coordinator.toggleCheckbox(at: CGPoint(x: 300, y: 300)))
    }

    @Test func backspaceAtAnItemStartRemovesTheMarkerAndKeepsIndentation() {
        let h = makeHarness("  - item")
        h.view.selectedRange = NSRange(location: 4, length: 0)
        h.view.deleteBackward()
        #expect(h.model.text == "  item")
        #expect(h.coordinator.displayedMarkers.isEmpty)

        let numbered = makeHarness("1. item")
        numbered.view.selectedRange = NSRange(location: 3, length: 0)
        numbered.view.deleteBackward()
        #expect(numbered.model.text == "item")

        let task = makeHarness("- [x] item")
        task.view.selectedRange = NSRange(location: 6, length: 0)
        task.view.deleteBackward()
        #expect(task.model.text == "item")
    }

    @Test func keyboardBackspaceOnAListPrefixIsWidenedOverTheWholePrefix() {
        let h = makeHarness("- item")
        let allowed = h.coordinator.textView(h.view, shouldChangeTextIn: NSRange(location: 1, length: 1), replacementText: "")
        #expect(!allowed)
        #expect(h.model.text == "item")

        let numbered = makeHarness("12. item")
        let allowedNumbered = numbered.coordinator.textView(numbered.view, shouldChangeTextIn: NSRange(location: 3, length: 1), replacementText: "")
        #expect(!allowedNumbered)
        #expect(numbered.model.text == "item")
    }

    @Test func caretStepsOverBulletAndTaskPrefixes() {
        let h = makeHarness("- item\n- [ ] task")
        h.view.selectedRange = NSRange(location: 0, length: 0)
        h.view.selectedRange = NSRange(location: 1, length: 0)
        #expect(h.view.selectedRange.location == 2)
        h.view.selectedRange = NSRange(location: 1, length: 0)
        #expect(h.view.selectedRange.location == 0)

        let start = 7
        h.view.selectedRange = NSRange(location: start + 3, length: 0)
        #expect([start, start + 6].contains(h.view.selectedRange.location))
        h.view.selectedRange = NSRange(location: start + 6, length: 0)
        h.view.selectedRange = NSRange(location: start + 5, length: 0)
        #expect(h.view.selectedRange.location == start)
    }

    @Test func listContinuationStillWorksOnReturn() {
        let h = makeHarness("- a")
        h.view.selectedRange = NSRange(location: 3, length: 0)
        _ = h.coordinator.textView(h.view, shouldChangeTextIn: NSRange(location: 3, length: 0), replacementText: "\n")
        h.view.insertText("\n")
        #expect(h.model.text == "- a\n")
        let continued = MarkdownFormatter.continueList(from: "- a", to: h.model.text, cursor: h.model.text.endIndex)
        #expect(continued?.text == "- a\n- ")
        h.model.text = continued!.text
        h.model.selection = TextSelection(insertionPoint: continued!.cursor)
        h.refresh()
        #expect(h.view.text == "- a\n- ")
        #expect(h.view.selectedRange == NSRange(location: 6, length: 0))
        #expect(h.coordinator.displayedMarkers.count == 2)
    }

    @Test func arrowingThroughAHiddenSyntaxDocumentStaysFast() {
        let paragraph = "Some *emphasis*, **bold**, `code`, [link](https://x.com) and #tag in a line.\n"
        let h = makeHarness(String(repeating: paragraph, count: 600))
        h.view.selectedRange = NSRange(location: 30_000, length: 0)
        let started = ContinuousClock.now
        for line in 1...20 {
            h.view.selectedRange = NSRange(location: 30_000 + line * 77, length: 0)
        }
        let perMove = (ContinuousClock.now - started) / 20
        #expect(perMove < .milliseconds(30), "\(perMove)")
        #expect(h.coordinator.recentlyStyled.suffix(2).allSatisfy { $0.length < 200 })
    }

    @Test func tappingTheTopEdgeOfALowerCheckboxTogglesThatOne() {
        let h = makeHarness("- [ ] one\n- [ ] two\n- [ ] three")
        h.view.selectedRange = NSRange(location: 0, length: 0)
        let boxes = glyphOverlays(h).sorted { $0.frame.minY < $1.frame.minY }
        guard boxes.count == 3 else {
            Issue.record("expected three checkbox overlays, found \(boxes.count)")
            return
        }
        let lower = boxes[1].frame
        #expect(h.coordinator.toggleCheckbox(at: CGPoint(x: lower.midX, y: lower.minY)))
        #expect(h.model.text == "- [ ] one\n- [x] two\n- [ ] three")

        let bottomEdge = boxes[1].frame
        #expect(h.coordinator.toggleCheckbox(at: CGPoint(x: bottomEdge.midX, y: bottomEdge.maxY)))
        #expect(h.model.text == "- [ ] one\n- [ ] two\n- [ ] three")
    }

    @Test func reindentingAnItemRestylesTheLevelsBelowIt() {
        let h = makeHarness("- a\n  - b\n    - c\n\nplain")
        #expect(h.coordinator.displayedMarkers.map(\.prefix.level) == [1, 2, 3])
        h.model.text = "- a\n- b\n    - c\n\nplain"
        h.refresh()
        #expect(h.coordinator.displayedMarkers.map(\.prefix.level) == [1, 1, 2])
        let style = h.view.textStorage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 20)

        h.model.text = "- a\n- b\n- c\n\nplain"
        h.refresh()
        #expect(h.coordinator.displayedMarkers.map(\.prefix.level) == [1, 1, 1])
        h.model.text = "- a\n- b\n    - c\n\nplain"
        h.refresh()
        h.model.text = "- a\nb\n    - c\n\nplain"
        h.refresh()
        #expect(h.coordinator.displayedMarkers.map(\.prefix.level) == [1, 1])
    }

    @Test func typingInsideAListItemDoesNotWidenTheRestyle() {
        let h = makeHarness((0..<50).map { "- item \($0)" }.joined(separator: "\n"))
        h.view.selectedRange = NSRange(location: 5, length: 0)
        _ = h.coordinator.textView(h.view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "x")
        h.view.insertText("x")
        let last = h.coordinator.recentlyStyled.last
        #expect((last?.length ?? 999) < 20)
    }

    // MARK: Growing height

    private func settle(_ h: Harness) async throws {
        h.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        h.view.frame.size.height = h.model.height
        h.view.layoutIfNeeded()
    }

    private var longProse: String { String(repeating: "A line of text that wraps around at some point. ", count: 80) }

    @Test func heightStaysAtTheMinimumForShortTextAndGrowsWithLongText() async throws {
        let short = makeHarness("hi")
        try await settle(short)
        #expect(short.model.height == MarkdownTextView.minHeight)

        let long = makeHarness(longProse)
        try await settle(long)
        #expect(long.model.height > 600)
        let before = long.model.height
        long.view.selectedRange = NSRange(location: long.view.text.utf16.count, length: 0)
        _ = long.coordinator.textView(long.view, shouldChangeTextIn: long.view.selectedRange, replacementText: "\n\nmore\n\nlines\n\nhere")
        long.view.insertText("\n\nmore\n\nlines\n\nhere")
        try await settle(long)
        #expect(long.model.height > before)
        #expect(!long.view.isScrollEnabled)
    }

    @Test func heightShrinksWhenTextIsRemoved() async throws {
        let h = makeHarness(longProse)
        try await settle(h)
        #expect(h.model.height > 600)
        h.model.text = "short"
        h.refresh()
        try await settle(h)
        #expect(h.model.height == MarkdownTextView.minHeight)
    }

    @Test func heightUpdateOnALargeBodyIsCheap() async throws {
        let paragraph = "Some *emphasis*, **bold**, `code`, [link](https://x.com) and #tag in a line of prose that wraps.\n"
        func medianKeystroke(_ h: Harness, at offset: Int) -> Duration {
            h.view.selectedRange = NSRange(location: offset, length: 0)
            let measuresBefore = h.coordinator.fullMeasureCount
            var samples: [Duration] = []
            for _ in 0..<21 {
                let range = h.view.selectedRange
                samples.append(ContinuousClock().measure {
                    _ = h.coordinator.textView(h.view, shouldChangeTextIn: range, replacementText: "x")
                    h.view.insertText("x")
                    h.view.layoutIfNeeded()
                })
            }
            // Typing within a line adds a wrapped line now and then, never one per keystroke.
            #expect(h.coordinator.fullMeasureCount - measuresBefore <= 3, "\(h.coordinator.fullMeasureCount - measuresBefore) full measures")
            return samples.sorted()[samples.count / 2]
        }

        var medians: [Int: Duration] = [:]
        for count in [50, 205, 510] {
            let h = makeHarness(String(repeating: paragraph, count: count))
            try await settle(h)
            try await settle(h)
            #expect(!h.view.isScrollEnabled)
            if count == 510 {
                #expect(h.model.height > 2_400)
                #expect(abs(h.view.frame.height - h.model.height) < 1)
            }
            medians[count] = medianKeystroke(h, at: count * paragraph.utf16.count / 2)
        }
        // The full-measure count above is the precise check; this only catches gross slowdowns.
        let small = medians[50]!
        #expect(medians[510]! < small * 30 + .milliseconds(100), "5k \(small), 20k \(medians[205]!), 50k \(medians[510]!)")
    }

    @Test func aLargeBodyNeverEnablesInternalScrolling() async throws {
        let h = makeHarness(String(repeating: "Another line of prose that is long enough to wrap around the view.\n", count: 300))
        try await settle(h)
        try await settle(h)
        #expect(h.model.height > 2_400)
        #expect(!h.view.isScrollEnabled)
    }

    @Test func atMostTwentyTaskActionsAreOffered() {
        let tasks = (0..<30).map { "- [ ] task \($0)" }.joined(separator: "\n")
        let h = makeHarness(tasks)
        h.view.selectedRange = NSRange(location: 8, length: 0)
        let names = taskActions(h).map(\.name)
        #expect(names.count == MarkdownTextView.Coordinator.maxTaskActions)
        #expect(names.first == "Toggle task: task 0")
        h.view.selectedRange = NSRange(location: (h.view.text as NSString).range(of: "task 25").location, length: 0)
        #expect(taskActions(h).count == 20)
        #expect(taskActions(h).first?.name == "Toggle task: task 25")
    }

    @Test func taskActionsSurviveAMarkerThatChangesLength() {
        let h = makeHarness("- [ ] Buy milk")
        h.view.selectedRange = NSRange(location: 6, length: 0)
        let stale = taskActions(h)
        h.model.text = "-  [ ] Buy milk"
        h.refresh()
        let fresh = taskActions(h)
        #expect(fresh.count == 1)
        h.grouped { #expect(stale[0].actionHandler?(stale[0]) == true) }
        #expect(h.model.text == "-  [x] Buy milk")
    }

    @Test func aTextSizeChangeInvalidatesTheHeightCache() async throws {
        let h = makeHarness(longProse)
        try await settle(h)
        #expect(h.coordinator.isHeightCacheValid)
        let before = h.model.height
        h.coordinator.contentSizeCategoryChanged()
        #expect(!h.coordinator.isHeightCacheValid)
        try await settle(h)
        #expect(h.coordinator.isHeightCacheValid)
        #expect(abs(h.model.height - before) < 2)
    }

    @Test func selectingDoesNotScrollTheForm() async throws {
        let h = makeHarness(longProse)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        h.window.addSubview(scroll)
        scroll.addSubview(h.view)
        h.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        try await settle(h)
        try await settle(h)
        scroll.contentSize = CGSize(width: 390, height: h.model.height)
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        h.view.selectedRange = NSRange(location: 100, length: 0)
        h.view.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)

        let length = (h.view.text as NSString).length
        h.view.selectedRange = NSRange(location: 0, length: length)
        h.view.layoutIfNeeded()
        #expect(scroll.contentOffset.y == 300)
        h.view.selectedRange = NSRange(location: 50, length: length - 50)
        h.view.layoutIfNeeded()
        #expect(scroll.contentOffset.y == 300)

        h.model.selection = TextSelection(insertionPoint: String.Index(utf16Offset: length, in: h.model.text))
        h.refresh()
        h.view.layoutIfNeeded()
        #expect(scroll.contentOffset.y == 300)
    }

    @Test func theInitialHeightEstimateIsCloseToTheMeasuredHeight() async throws {
        #expect(MarkdownTextView.estimatedHeight(for: "hi", width: 358) == MarkdownTextView.minHeight)
        let huge = String(repeating: "A line of text that wraps around at some point. ", count: 1_000)
        let hugeEstimate = MarkdownTextView.estimatedHeight(for: huge, width: 358)
        #expect(hugeEstimate > 2_400)
        let hugeHarness = makeHarness(huge)
        try await settle(hugeHarness)
        try await settle(hugeHarness)
        #expect(abs(hugeEstimate - hugeHarness.model.height) < hugeHarness.model.height * 0.3, "estimate \(hugeEstimate), measured \(hugeHarness.model.height)")
        let estimate = MarkdownTextView.estimatedHeight(for: longProse, width: 390)
        let h = makeHarness(longProse)
        try await settle(h)
        #expect(abs(estimate - h.model.height) < h.model.height * 0.25, "estimate \(estimate), measured \(h.model.height)")
    }

    @Test func overlaysStayAlignedAsTheViewGrows() async throws {
        let list = (0..<40).map { "- item \($0) " + String(repeating: "word ", count: 12) }.joined(separator: "\n")
        let h = makeHarness(list)
        try await settle(h)
        let overlays = glyphOverlays(h).sorted { $0.frame.minY < $1.frame.minY }
        #expect(overlays.count == 40)
        guard let last = overlays.last else { return }
        let lastMarker = h.coordinator.displayedMarkers.last!
        let lineTop = h.view.caretRect(for: h.view.position(from: h.view.beginningOfDocument, offset: lastMarker.range.location)!)
        #expect(abs(last.frame.midY - lineTop.midY) < 6)
        #expect(last.frame.minY > 500)
    }

    @Test func caretIsScrolledIntoViewInTheEnclosingScrollView() async throws {
        let h = makeHarness(longProse)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        h.window.addSubview(scroll)
        scroll.addSubview(h.view)
        h.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        try await settle(h)
        scroll.contentSize = CGSize(width: 390, height: h.model.height)

        h.view.selectedRange = NSRange(location: h.view.text.utf16.count, length: 0)
        h.coordinator.scrollCaretIntoView()
        let caret = scroll.convert(h.view.caretRect(for: h.view.selectedTextRange!.end), from: h.view)
        #expect(scroll.contentOffset.y > 0)
        #expect(caret.maxY <= scroll.contentOffset.y + scroll.bounds.height)
        #expect(caret.minY >= scroll.contentOffset.y)

        scroll.setContentOffset(.zero, animated: false)
        let range = h.view.selectedRange
        _ = h.coordinator.textView(h.view, shouldChangeTextIn: range, replacementText: "\n")
        h.view.insertText("\n")
        try await settle(h)
        try await settle(h)
        scroll.contentSize = CGSize(width: 390, height: h.model.height)
        h.view.setNeedsLayout()
        h.view.layoutIfNeeded()
        let moved = scroll.convert(h.view.caretRect(for: h.view.selectedTextRange!.end), from: h.view)
        #expect(scroll.contentOffset.y > 0)
        #expect(moved.maxY <= scroll.contentOffset.y + scroll.bounds.height + 1)
    }

    // MARK: Accessibility

    private func taskActions(_ h: Harness) -> [UIAccessibilityCustomAction] {
        h.view.layoutIfNeeded()
        return h.view.accessibilityCustomActions ?? []
    }

    @Test func taskActionsNameTheTaskOnTheCaretLineFirst() {
        let h = makeHarness("- [ ] Buy milk\n- [x] Call Sam\nplain")
        h.view.selectedRange = NSRange(location: 20, length: 0)
        #expect(taskActions(h).map(\.name) == ["Toggle task: Call Sam", "Toggle task: Buy milk"])
        h.view.selectedRange = NSRange(location: 3, length: 0)
        #expect(taskActions(h).map(\.name) == ["Toggle task: Buy milk", "Toggle task: Call Sam"])
        h.view.selectedRange = NSRange(location: 31, length: 0)
        #expect(taskActions(h).map(\.name) == ["Toggle task: Buy milk", "Toggle task: Call Sam"])
    }

    @Test func taskActionTogglesTheTaskAndIsUndoable() {
        let h = makeHarness("- [ ] Buy milk\n- [x] Call Sam")
        h.view.selectedRange = NSRange(location: 6, length: 0)
        let actions = taskActions(h)
        h.grouped { #expect(actions[1].actionHandler?(actions[1]) == true) }
        #expect(h.model.text == "- [ ] Buy milk\n- [ ] Call Sam")
        #expect(h.view.selectedRange == NSRange(location: 6, length: 0))

        h.view.undoManager?.undo()
        #expect(h.model.text == "- [ ] Buy milk\n- [x] Call Sam")

        let refreshed = taskActions(h)
        #expect(refreshed.map(\.name) == ["Toggle task: Buy milk", "Toggle task: Call Sam"])
        h.grouped { #expect(refreshed[0].actionHandler?(refreshed[0]) == true) }
        #expect(h.model.text == "- [x] Buy milk\n- [x] Call Sam")
    }

    @Test func noTasksMeansNoTaskActions() {
        let h = makeHarness("- plain bullet\ntext")
        #expect(taskActions(h).isEmpty)
    }

    @Test func largeBodyTypingStaysFast() {
        let paragraph = "Some *emphasis*, **bold**, `code`, [link](https://x.com) and #tag in a line of prose.\n"
        let h = makeHarness(String(repeating: paragraph, count: 600))
        h.view.selectedRange = NSRange(location: 30_000, length: 0)
        let started = ContinuousClock.now
        for _ in 0..<20 {
            // The keyboard announces each edit through the delegate; programmatic insertText doesn't.
            let range = h.view.selectedRange
            _ = h.coordinator.textView(h.view, shouldChangeTextIn: range, replacementText: "x")
            h.view.insertText("x")
        }
        let perKeystroke = (ContinuousClock.now - started) / 20
        #expect(perKeystroke < .milliseconds(30), "\(perKeystroke)")
    }
}
