import Testing
@testable import ThoughtReps

@Suite("MarkdownFormatter")
struct MarkdownFormatterTests {
    /// Result rendered with `[` `]` around the selection, or `|` for an insertion point.
    private func render(_ edit: MarkdownFormatter.Edit) -> String {
        var s = edit.text
        if edit.selection.isEmpty {
            s.insert("|", at: edit.selection.lowerBound)
        } else {
            s.insert("]", at: edit.selection.upperBound)
            s.insert("[", at: edit.selection.lowerBound)
        }
        return s
    }

    /// Input where `[` `]` mark a selection or `|` an insertion point.
    private func run(_ input: String, _ action: (String, Range<String.Index>) -> MarkdownFormatter.Edit) -> String {
        var text = input
        let range: Range<String.Index>
        if let bar = text.firstIndex(of: "|") {
            let offset = text.utf16.distance(from: text.startIndex, to: bar)
            text.remove(at: bar)
            let i = String.Index(utf16Offset: offset, in: text)
            range = i..<i
        } else {
            let open = text.firstIndex(of: "[")!
            let openOffset = text.utf16.distance(from: text.startIndex, to: open)
            text.remove(at: open)
            let close = text.firstIndex(of: "]")!
            let closeOffset = text.utf16.distance(from: text.startIndex, to: close)
            text.remove(at: close)
            range = String.Index(utf16Offset: openOffset, in: text)..<String.Index(utf16Offset: closeOffset, in: text)
        }
        return render(action(text, range))
    }

    private func inline(_ style: MarkdownFormatter.Inline, _ input: String) -> String {
        run(input) { MarkdownFormatter.toggle(style, in: $0, selection: $1) }
    }

    private func prefix(_ kind: MarkdownFormatter.LinePrefix, _ input: String) -> String {
        run(input) { MarkdownFormatter.toggle(kind, in: $0, selection: $1) }
    }

    private func continued(_ old: String, inserting at: Int, hint: Bool = false) -> (text: String, cursor: Int)? {
        var new = old
        new.insert("\n", at: String.Index(utf16Offset: at, in: new))
        let cursor = hint ? String.Index(utf16Offset: at + 1, in: new) : nil
        guard let result = MarkdownFormatter.continueList(from: old, to: new, cursor: cursor) else { return nil }
        return (result.text, result.cursor.utf16Offset(in: result.text))
    }

    // MARK: Inline

    @Test func insertsEmptyPairAtCursor() {
        #expect(inline(.bold, "|") == "**|**")
        #expect(inline(.italic, "ab|cd") == "ab_|_cd")
        #expect(inline(.code, "abc|") == "abc`|`")
        #expect(inline(.bold, "|abc") == "**|**abc")
    }

    @Test func wrapsSelectionKeepingItSelected() {
        #expect(inline(.bold, "a [word] b") == "a **[word]** b")
        #expect(inline(.italic, "[all]") == "_[all]_")
        #expect(inline(.code, "x [y]") == "x `[y]`")
    }

    @Test func unwrapsWhenMarkersOutsideSelection() {
        #expect(inline(.bold, "a **[word]** b") == "a [word] b")
        #expect(inline(.italic, "_[x]_") == "[x]")
    }

    @Test func unwrapsWhenSelectionIncludesMarkers() {
        #expect(inline(.bold, "a [**word**] b") == "a [word] b")
        #expect(inline(.code, "[`x`]") == "[x]")
    }

    @Test func unwrapsEmptyPairAtCursor() {
        #expect(inline(.bold, "**|**") == "|")
        #expect(inline(.italic, "a_|_b") == "a|b")
    }

    @Test func differentMarkerDoesNotUnwrap() {
        #expect(inline(.italic, "**[word]**") == "**_[word]_**")
    }

    // MARK: Line prefixes

    @Test func addsPrefixAndKeepsCursorOnSameCharacter() {
        #expect(prefix(.heading, "|") == "# |")
        #expect(prefix(.bullet, "abc|") == "- abc|")
        #expect(prefix(.bullet, "a|bc") == "- a|bc")
        #expect(prefix(.task, "|abc") == "- [ ] |abc")
    }

    @Test func appliesToLineOfCursorOnly() {
        #expect(prefix(.bullet, "one\ntw|o\nthree") == "one\n- tw|o\nthree")
        #expect(prefix(.heading, "one\ntwo|") == "one\n# two|")
        #expect(prefix(.task, "one\n|\nthree") == "one\n- [ ] |\nthree")
    }

    @Test func removesPrefixWhenAlreadyPresent() {
        #expect(prefix(.heading, "# ab|c") == "ab|c")
        #expect(prefix(.bullet, "- |") == "|")
        #expect(prefix(.task, "- [ ] abc|") == "abc|")
        #expect(prefix(.task, "- [x] abc|") == "abc|")
    }

    @Test func cursorInsideRemovedPrefixMovesToLineStart() {
        #expect(prefix(.task, "- [ |] abc") == "|abc")
    }

    @Test func replacesDifferentPrefix() {
        #expect(prefix(.task, "- abc|") == "- [ ] abc|")
        #expect(prefix(.bullet, "- [ ] abc|") == "- abc|")
        #expect(prefix(.heading, "- abc|") == "# abc|")
        #expect(prefix(.bullet, "# abc|") == "- abc|")
    }

    @Test func multiLineSelectionAppliesToEveryLine() {
        #expect(prefix(.bullet, "[one\ntwo\nthree]") == "[- one\n- two\n- three]")
        #expect(prefix(.bullet, "one\n[two\nthr]ee") == "one\n[- two\n- thr]ee")
    }

    @Test func multiLineMixedAddsToAllAndUniformRemoves() {
        #expect(prefix(.bullet, "[- one\ntwo]") == "[- one\n- two]")
        #expect(prefix(.bullet, "[- one\n- two]") == "[one\ntwo]")
        #expect(prefix(.task, "[- one\n- two]") == "[- [ ] one\n- [ ] two]")
    }

    @Test func multiLineSkipsBlankLines() {
        #expect(prefix(.bullet, "[one\n\ntwo]") == "[- one\n\n- two]")
        #expect(prefix(.bullet, "[one\n  \ntwo]") == "[- one\n  \n- two]")
        #expect(prefix(.bullet, "[- one\n\n- two]") == "[one\n\ntwo]")
        #expect(prefix(.task, "[- one\n\ntwo]") == "[- [ ] one\n\n- [ ] two]")
        #expect(prefix(.heading, "[one\n\n\ntwo\n]") == "[# one\n\n\n# two\n]")
    }

    @Test func blankLinesDoNotBlockToggleOff() {
        #expect(prefix(.bullet, "[- one\n\n- two\n\n- three]") == "[one\n\ntwo\n\nthree]")
    }

    @Test func selectionAdjustsAroundSkippedLines() {
        #expect(prefix(.bullet, "a\n[one\n\ntw]o") == "a\n[- one\n\n- tw]o")
        #expect(prefix(.bullet, "[\none\ntwo]") == "[\n- one\n- two]")
    }

    @Test func singleEmptyLineStillPrefixes() {
        #expect(prefix(.bullet, "|") == "- |")
        #expect(prefix(.task, "one\n|\ntwo") == "one\n- [ ] |\ntwo")
    }

    @Test func allBlankMultiLineSelectionStillPrefixes() {
        #expect(prefix(.bullet, "[\n\n]") == "[- \n- \n]")
    }

    @Test func selectionEndingAtLineStartExcludesNextLine() {
        #expect(prefix(.bullet, "[one\n]two") == "[- one\n]two")
    }

    // MARK: List continuation

    @Test func continuesBullet() throws {
        let r = try #require(continued("- one", inserting: 5))
        #expect(r.text == "- one\n- ")
        #expect(r.cursor == 8)
    }

    @Test func continuesTaskUnchecked() throws {
        let r = try #require(continued("- [x] done", inserting: 10))
        #expect(r.text == "- [x] done\n- [ ] ")
        #expect(r.cursor == r.text.utf16.count)
    }

    @Test func continuesOrderedListIncrementing() throws {
        #expect(try #require(continued("1. a", inserting: 4)).text == "1. a\n2. ")
        #expect(try #require(continued("9. a", inserting: 4)).text == "9. a\n10. ")
    }

    @Test func continuesInMiddleOfText() throws {
        let r = try #require(continued("- a\nafter", inserting: 3, hint: true))
        #expect(r.text == "- a\n- \nafter")
        #expect(r.cursor == 6)
    }

    @Test func newlineNextToAnotherNeedsCursorToLocate() throws {
        #expect(continued("- a\n\nafter", inserting: 3) == nil)
        #expect(try #require(continued("- a\n\nafter", inserting: 3, hint: true)).text == "- a\n- \n\nafter")
        #expect(continued("- a\n\nafter", inserting: 4, hint: true) == nil)
    }

    @Test func splitsItemWhenReturnPressedMidLine() throws {
        let r = try #require(continued("- ab", inserting: 3))
        #expect(r.text == "- a\n- b")
        #expect(r.cursor == 6)
    }

    @Test func keepsIndent() throws {
        #expect(try #require(continued("  - a", inserting: 5)).text == "  - a\n  - ")
    }

    @Test func emptyItemEndsList() throws {
        let r = try #require(continued("- a\n- ", inserting: 6))
        #expect(r.text == "- a\n")
        #expect(r.cursor == 4)

        let only = try #require(continued("- [ ] ", inserting: 6))
        #expect(only.text == "")
        #expect(only.cursor == 0)

        let numbered = try #require(continued("1. a\n2. ", inserting: 8))
        #expect(numbered.text == "1. a\n")
    }

    @Test func returnRightAfterPrefixSplitsInsteadOfExiting() throws {
        #expect(try #require(continued("- abc", inserting: 2)).text == "- \n- abc")
        #expect(try #require(continued("- [ ] abc", inserting: 6)).text == "- [ ] \n- [ ] abc")
        #expect(try #require(continued("1. abc", inserting: 3)).text == "1. \n2. abc")
    }

    @Test func emptyItemBeforeFollowingLineStillEndsList() throws {
        #expect(try #require(continued("- \nnext", inserting: 2, hint: true)).text == "\nnext")
    }

    @Test func staleCursorHintNextToAnotherNewlineIsSafe() {
        let old = "- a\n\nafter"
        let new = "- a\n\n\nafter"
        for offset in [0, 3, 5, 6, 20] {
            let hint = String.Index(utf16Offset: min(offset, new.utf16.count), in: new)
            #expect(MarkdownFormatter.continueList(from: old, to: new, cursor: hint) == nil)
        }
    }

    // MARK: Multi-byte text

    @Test func inlineToggleWithEmojiAndCombiningCharacters() {
        #expect(inline(.bold, "\u{1F44B}\u{1F3FD} [e\u{301}x] \u{1F44B}\u{1F3FD}") == "\u{1F44B}\u{1F3FD} **[e\u{301}x]** \u{1F44B}\u{1F3FD}")
        #expect(inline(.italic, "e\u{301} [\u{1F44B}\u{1F3FD}]") == "e\u{301} _[\u{1F44B}\u{1F3FD}]_")
        #expect(inline(.code, "\u{1F44B}\u{1F3FD} `[e\u{301}]`") == "\u{1F44B}\u{1F3FD} [e\u{301}]")
        #expect(inline(.bold, "\u{1F44B}\u{1F3FD}|e\u{301}") == "\u{1F44B}\u{1F3FD}**|**e\u{301}")
    }

    @Test func prefixToggleWithEmojiAndCombiningCharacters() {
        #expect(prefix(.bullet, "\u{1F44B}\u{1F3FD}\ne\u{301}|x") == "\u{1F44B}\u{1F3FD}\n- e\u{301}|x")
        #expect(prefix(.task, "- \u{1F44B}\u{1F3FD} [e\u{301}x]") == "- [ ] \u{1F44B}\u{1F3FD} [e\u{301}x]")
        #expect(prefix(.heading, "# e\u{301}\u{1F44B}\u{1F3FD}|") == "e\u{301}\u{1F44B}\u{1F3FD}|")
        #expect(prefix(.bullet, "[\u{1F44B}\u{1F3FD}\ne\u{301}]") == "[- \u{1F44B}\u{1F3FD}\n- e\u{301}]")
    }

    @Test func continuesListWithEmojiEarlierAndOnTheLine() throws {
        let text = "\u{1F44B}\u{1F3FD} hi\n- e\u{301}\u{1F44B}\u{1F3FD}"
        let r = try #require(continued(text, inserting: text.utf16.count))
        #expect(r.text == text + "\n- ")
        #expect(r.cursor == r.text.utf16.count)
        let split = try #require(continued("\u{1F44B}\u{1F3FD}\n- \u{1F44B}b", inserting: 9))
        #expect(split.text == "\u{1F44B}\u{1F3FD}\n- \u{1F44B}\n- b")
    }

    @Test func ignoresNonListAndNonNewlineChanges() {
        #expect(continued("plain", inserting: 5) == nil)
        #expect(continued("# heading", inserting: 9) == nil)
        #expect(MarkdownFormatter.continueList(from: "- a", to: "- ab") == nil)
        #expect(MarkdownFormatter.continueList(from: "- a\n", to: "- a") == nil)
        #expect(MarkdownFormatter.continueList(from: "- a", to: "- a\n- ") == nil)
    }
}
