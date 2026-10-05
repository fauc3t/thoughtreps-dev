import Foundation

/// Selection-aware Markdown editing for the editor's format bar and list continuation.
/// Pure: takes text and a selection, returns new text and the selection to restore.
/// Offsets are computed in UTF-16 units so indices from the old text are never reused on the new one.
enum MarkdownFormatter {
    enum Inline {
        case bold, italic, code

        var marker: String {
            switch self {
            case .bold: "**"
            case .italic: "_"
            case .code: "`"
            }
        }
    }

    enum LinePrefix: CaseIterable {
        case heading, bullet, task

        var marker: String {
            switch self {
            case .heading: "# "
            case .bullet: "- "
            case .task: "- [ ] "
            }
        }

        /// Every spelling of the prefix that counts as this kind, longest first.
        fileprivate var spellings: [String] {
            switch self {
            case .heading: ["# "]
            case .bullet: ["- "]
            case .task: ["- [ ] ", "- [x] ", "- [X] "]
            }
        }
    }

    typealias Edit = (text: String, selection: Range<String.Index>)

    // MARK: Inline markers

    /// Wraps the selection in the marker, keeping the inner text selected; with an insertion
    /// point, inserts an empty pair and puts the cursor between. Toggles off when the selection
    /// is already wrapped, whether the markers are inside or just outside it.
    static func toggle(_ style: Inline, in text: String, selection: Range<String.Index>) -> Edit {
        let units = Array(text.utf16)
        let (start, end) = offsets(selection, in: text)
        let marker = Array(style.marker.utf16)
        let m = marker.count

        var result = units
        var newStart = start
        var newEnd = end

        let isWrappedInside = end - start >= 2 * m
            && units[start..<(start + m)].elementsEqual(marker)
            && units[(end - m)..<end].elementsEqual(marker)
        let isWrappedOutside = start >= m && end + m <= units.count
            && units[(start - m)..<start].elementsEqual(marker)
            && units[end..<(end + m)].elementsEqual(marker)

        if isWrappedInside {
            result.removeSubrange((end - m)..<end)
            result.removeSubrange(start..<(start + m))
            newEnd = end - 2 * m
        } else if isWrappedOutside {
            result.removeSubrange(end..<(end + m))
            result.removeSubrange((start - m)..<start)
            newStart = start - m
            newEnd = end - m
        } else {
            result.insert(contentsOf: marker, at: end)
            result.insert(contentsOf: marker, at: start)
            newStart = start + m
            newEnd = end + m
        }
        return edit(result, newStart, newEnd)
    }

    // MARK: Line prefixes

    /// Adds `prefix` to every line the selection touches, removes it when all of them already
    /// have it, and replaces a different heading, bullet or task prefix. Blank lines in a
    /// multi-line selection are skipped, except that a single empty line, or a selection of
    /// only blank lines, still gets the prefix. The selection keeps pointing at the same characters.
    static func toggle(_ prefix: LinePrefix, in text: String, selection: Range<String.Index>) -> Edit {
        let units = Array(text.utf16)
        let (start, end) = offsets(selection, in: text)
        let allLines = lineStarts(in: units, covering: start, end)
        let nonBlank = allLines.filter { !isBlank(in: units, lineStart: $0) }
        let lines = nonBlank.isEmpty ? allLines : nonBlank
        let existing = lines.map { existingPrefix(in: units, at: $0) }
        let removing = existing.allSatisfy { $0?.kind == prefix }

        let replacement = removing ? [] : Array(prefix.marker.utf16)
        var result = units
        var changes: [(start: Int, oldLength: Int)] = []
        for (lineStart, old) in zip(lines, existing).reversed() {
            let oldLength = old?.length ?? 0
            result.replaceSubrange(lineStart..<(lineStart + oldLength), with: replacement)
            changes.append((lineStart, oldLength))
        }

        func shifted(_ offset: Int, keepsLineStart: Bool = false) -> Int {
            var delta = 0
            for change in changes {
                if keepsLineStart && offset == change.start { continue }
                if offset >= change.start + change.oldLength {
                    delta += replacement.count - change.oldLength
                } else if offset > change.start {
                    delta += min(offset - change.start, replacement.count) - (offset - change.start)
                }
            }
            return offset + delta
        }
        return edit(result, shifted(start, keepsLineStart: start < end), shifted(end))
    }

    // MARK: List continuation

    /// If `new` is `old` with a single newline typed after a list item, returns the text with
    /// the next item's prefix added (a task continues unchecked, a number increments). On an
    /// empty item the prefix is removed instead, ending the list. Nil for any other change.
    /// `cursor` is the insertion point after the typed newline; it is only needed to locate the
    /// newline when it was typed next to another one, which looks identical in the text.
    static func continueList(
        from old: String,
        to new: String,
        cursor: String.Index? = nil
    ) -> (text: String, cursor: String.Index)? {
        guard old.utf16.count + 1 == new.utf16.count else { return nil }
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)

        var firstDifference = 0
        while firstDifference < oldUnits.count, oldUnits[firstDifference] == newUnits[firstDifference] { firstDifference += 1 }
        guard newUnits[firstDifference] == newline,
              Array(newUnits[..<firstDifference] + newUnits[(firstDifference + 1)...]) == oldUnits
        else { return nil }

        var runStart = firstDifference
        while runStart > 0, newUnits[runStart - 1] == newline { runStart -= 1 }
        var at = firstDifference
        if runStart < firstDifference {
            guard let cursor else { return nil }
            at = min(cursor.utf16Offset(in: new), newUnits.count) - 1
            guard (runStart...firstDifference).contains(at) else { return nil }
        }

        let lineStart = (newUnits[..<at].lastIndex(of: newline)).map { $0 + 1 } ?? 0
        let line = Array(newUnits[lineStart..<at])
        guard let item = listItem(in: line) else { return nil }

        let restOfLineIsEmpty = newUnits[(at + 1)...].first.map { $0 == newline } ?? true
        if line.count == item.prefixLength && restOfLineIsEmpty {
            var result = newUnits
            result.removeSubrange(lineStart...at)
            return (decode(result), String.Index(utf16Offset: lineStart, in: decode(result)))
        }

        var result = newUnits
        let insertion = Array(item.nextPrefix.utf16)
        result.insert(contentsOf: insertion, at: at + 1)
        let text = decode(result)
        return (text, String.Index(utf16Offset: at + 1 + insertion.count, in: text))
    }

    // MARK: Helpers

    private static let newline: UInt16 = 0x0A

    private static func offsets(_ range: Range<String.Index>, in text: String) -> (Int, Int) {
        let upper = min(range.upperBound.utf16Offset(in: text), text.utf16.count)
        let lower = min(range.lowerBound.utf16Offset(in: text), upper)
        return (lower, upper)
    }

    private static func decode(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self)
    }

    private static func edit(_ units: [UInt16], _ start: Int, _ end: Int) -> Edit {
        let text = decode(units)
        let lower = String.Index(utf16Offset: start, in: text)
        let upper = String.Index(utf16Offset: end, in: text)
        return (text, lower..<upper)
    }

    /// Start offsets of the lines from the one containing `start` through the one containing `end`.
    /// A non-empty selection ending right after a newline doesn't include the following line.
    private static func lineStarts(in units: [UInt16], covering start: Int, _ end: Int) -> [Int] {
        func lineStart(of offset: Int) -> Int {
            (units[..<offset].lastIndex(of: newline)).map { $0 + 1 } ?? 0
        }
        let first = lineStart(of: start)
        let lastOffset = end > start && units[end - 1] == newline ? end - 1 : end
        var starts = [first]
        var index = first
        while let next = units[index...].firstIndex(of: newline), next + 1 <= lastOffset {
            starts.append(next + 1)
            index = next + 1
        }
        return starts
    }

    private static func isBlank(in units: [UInt16], lineStart: Int) -> Bool {
        units[lineStart...].prefix { $0 != newline }.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func existingPrefix(in units: [UInt16], at lineStart: Int) -> (kind: LinePrefix, length: Int)? {
        for kind in [LinePrefix.task, .bullet, .heading] {
            for spelling in kind.spellings {
                let candidate = Array(spelling.utf16)
                if units[lineStart...].starts(with: candidate) { return (kind, candidate.count) }
            }
        }
        return nil
    }

    private static func listItem(in line: [UInt16]) -> (prefixLength: Int, nextPrefix: String)? {
        let indentLength = line.prefix { $0 == 0x20 || $0 == 0x09 }.count
        let indent = decode(Array(line[..<indentLength]))
        let body = Array(line[indentLength...])

        for spelling in LinePrefix.task.spellings {
            if body.starts(with: Array(spelling.utf16)) {
                return (indentLength + spelling.utf16.count, indent + LinePrefix.task.marker)
            }
        }
        if body.starts(with: Array(LinePrefix.bullet.marker.utf16)) {
            return (indentLength + 2, indent + LinePrefix.bullet.marker)
        }

        let digits = body.prefix { $0 >= 0x30 && $0 <= 0x39 }
        if !digits.isEmpty, digits.count <= 9, body.dropFirst(digits.count).starts(with: Array(". ".utf16)),
           let number = Int(decode(Array(digits))) {
            return (indentLength + digits.count + 2, "\(indent)\(number + 1). ")
        }
        return nil
    }
}
