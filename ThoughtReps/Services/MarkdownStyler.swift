import Foundation

/// Scans Markdown into style runs for the live-styled editor. Pure: the text is never changed,
/// and every range is in UTF-16 units of the input.
///
/// Runs may overlap (`**a _b_**` gives bold over everything and italic over `_b_`), and syntax
/// characters get their own `.syntax` runs on top of the style they belong to, so a view can
/// fade them. Inline styles end at a line break; blocks are recognized per line, with fenced
/// code tracked from the start of the text. Tags follow `TagParser`'s rules.
enum MarkdownStyler {
    enum Style: Equatable, Hashable {
        /// Covers the `#`s and the heading text.
        case heading(level: Int)
        case bold, italic, strikethrough
        /// The whole span including its backticks.
        case inlineCode
        /// Whole lines of a fenced block including the fences and line terminators.
        case codeBlock
        /// From the first `>` to the end of the line.
        case blockquote
        case listMarker
        case taskMarker(checked: Bool)
        /// The link text, or the whole URL for autolinks and bare URLs.
        case link
        /// `#` plus the tag.
        case tag
        /// A whole `![](img:<uuid>)` token.
        case image(UUID)
        /// Markers a view fades, or hides away from the cursor: `**`, `_`, `~~`, backticks, a heading's
        /// `#`s and the spaces after them, a quote's `>` and its space, link brackets and URLs.
        case syntax
        /// A whole fence line including its terminator. It always comes with `.codeBlock`.
        case fence
        /// A whole `---` line.
        case thematicBreak
        /// A list item's marker, an optional task box and the spaces after them: the unit a view draws as a glyph.
        case listPrefix(ListPrefix)
    }

    struct ListPrefix: Equatable, Hashable {
        enum Kind: Equatable, Hashable {
            case bullet
            case numbered
            case task(checked: Bool)
        }

        let kind: Kind
        /// 1 for a top-level item, deeper by indentation.
        let level: Int
        /// The marker alone (`-`, `12.`), without the spaces or task box.
        let markerLength: Int
    }

    struct Run: Equatable {
        let range: NSRange
        let style: Style
    }

    /// Runs for every line `range` touches (all lines when nil), in text order per line.
    static func runs(in text: String, range: NSRange? = nil) -> [Run] {
        runs(in: Array(text.utf16), range: range)
    }

    static func runs(in units: [UInt16], range: NSRange? = nil) -> [Run] {
        let all = lines(in: units)
        let target = range.map { clamp($0, to: units.count) } ?? NSRange(location: 0, length: units.count)
        let upper = max(target.upperBound, target.location + 1)
        var result: [Run] = []
        var linked: [NSRange] = []
        var touched: [Line] = []
        let levels = listLevels(units, all, upTo: upper)
        for (index, line) in all.enumerated() where line.start < upper && line.end > target.location {
            result.append(contentsOf: styleLine(units, line, level: levels[index], linked: &linked))
            touched.append(line)
        }
        result.append(contentsOf: tagRuns(units, lines: touched, linked: linked))
        return result
    }

    /// The line-aligned range to restyle after an edit that left `edited` (in the new text)
    /// holding the new content. Spans the lines the edit touches. Fences pair up through the
    /// rest of the text, so when a fence line is involved (`fenceChanged` says one was edited
    /// away) the range runs to the end of the text.
    static func restyleRange(in text: String, edited: NSRange, fenceChanged: Bool = false) -> NSRange {
        restyleRange(in: Array(text.utf16), edited: edited, fenceChanged: fenceChanged)
    }

    /// `listChanged` (see `listSignature`) also widens the range to the end of the list block, since
    /// nesting levels depend on the items above.
    static func restyleRange(in units: [UInt16], edited: NSRange, fenceChanged: Bool = false, listChanged: Bool = false) -> NSRange {
        let region = lineAlignedRange(in: units, covering: edited)
        let widens = fenceChanged || hasFenceMarker(Array(units[region.location..<region.upperBound]))
        if widens { return NSRange(location: region.location, length: units.count - region.location) }
        guard listChanged else { return region }
        let end = listBlockEnd(units, from: region.upperBound)
        return NSRange(location: region.location, length: end - region.location)
    }

    /// One number per line of `units`: 0 for a line that isn't a list item, otherwise its indentation
    /// and whether the marker is numbered. It differs before and after an edit exactly when the edit
    /// added, removed or re-indented a list item or changed its marker kind.
    static func listSignature(of units: [UInt16]) -> [Int] {
        var signature: [Int] = []
        var start = 0
        while start < units.count {
            let contentEnd = units[start...].firstIndex(of: newline) ?? units.count
            signature.append(listLineSignature(units, start, contentEnd))
            start = contentEnd + 1
        }
        return signature
    }

    private static func listLineSignature(_ units: [UInt16], _ start: Int, _ end: Int) -> Int {
        var i = start
        while i < end, units[i] == space || units[i] == tab { i += 1 }
        guard i < end else { return 0 }
        let first = units[i]
        guard first == ch("-") || first == ch("+") || first == ch("*") || (first >= ch("0") && first <= ch("9")),
              let item = listItem(units, from: start, to: end, level: 0),
              case let .listPrefix(prefix)? = item.runs.last?.style
        else { return 0 }
        let indent = units[start..<i].reduce(0) { $0 + ($1 == tab ? 4 : 1) }
        return 1 + indent * 2 + (prefix.kind == .numbered ? 1 : 0)
    }

    /// The end of the run of list items, their indented continuations and blank lines that begins at `offset`.
    private static func listBlockEnd(_ units: [UInt16], from offset: Int) -> Int {
        var end = offset
        var start = offset
        while start < units.count {
            let contentEnd = units[start...].firstIndex(of: newline) ?? units.count
            let blank = units[start..<contentEnd].allSatisfy { $0 == space || $0 == tab }
            let indented = contentEnd > start && (units[start] == space || units[start] == tab)
            guard blank || indented || listLineSignature(units, start, contentEnd) != 0 else { break }
            start = min(contentEnd + 1, units.count)
            end = start
            if contentEnd == units.count { break }
        }
        return end
    }

    /// The lines `range` touches, whole.
    static func lineAlignedRange(in units: [UInt16], covering range: NSRange) -> NSRange {
        let range = clamp(range, to: units.count)
        let start = lineStart(units, at: range.location)
        let end = lineEnd(units, from: range.upperBound)
        return NSRange(location: start, length: end - start)
    }

    /// True when any line of `units` looks like a code fence, whether or not it opens or closes one.
    static func hasFenceMarker(_ units: [UInt16]) -> Bool {
        var start = 0
        while start < units.count {
            let contentEnd = units[start...].firstIndex(of: newline) ?? units.count
            if fenceMarker(units, start, contentEnd) != nil { return true }
            start = contentEnd + 1
        }
        return false
    }

    // MARK: Lines

    private enum LineKind { case normal, fenceOpen, fenceBody, fenceClose }

    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
        let kind: LineKind
    }

    private struct Fence {
        let marker: UInt16
        let count: Int
    }

    private static let newline: UInt16 = 0x0A
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let mask: UInt16 = 0x01

    private static func ch(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let upper = min(max(range.upperBound, location), length)
        return NSRange(location: location, length: upper - location)
    }

    private static func lineStart(_ units: [UInt16], at offset: Int) -> Int {
        var i = min(offset, units.count)
        while i > 0, units[i - 1] != newline { i -= 1 }
        return i
    }

    /// The offset just past the line terminator of the line containing `offset`.
    private static func lineEnd(_ units: [UInt16], from offset: Int) -> Int {
        guard offset < units.count else { return units.count }
        return (units[offset...].firstIndex(of: newline)).map { $0 + 1 } ?? units.count
    }

    private static func lines(in units: [UInt16]) -> [Line] {
        var result: [Line] = []
        var open: Fence?
        var start = 0
        while start < units.count {
            let contentEnd = units[start...].firstIndex(of: newline) ?? units.count
            let end = min(contentEnd + 1, units.count)
            var kind = LineKind.normal
            if let current = open {
                if isClosingFence(units, start, contentEnd, current) {
                    kind = .fenceClose
                    open = nil
                } else {
                    kind = .fenceBody
                }
            } else if let marker = fenceMarker(units, start, contentEnd) {
                kind = .fenceOpen
                open = Fence(marker: marker.char, count: marker.count)
            }
            result.append(Line(start: start, contentEnd: contentEnd, end: end, kind: kind))
            start = end
        }
        return result
    }

    private static func skipSpaces(_ units: [UInt16], _ from: Int, _ end: Int, max: Int) -> Int {
        var i = from
        while i < end, i - from < max, units[i] == space { i += 1 }
        return i
    }

    /// A run of three or more backticks or tildes after at most three spaces. Backtick fences
    /// can't have a backtick later on the line (that is inline code).
    private static func fenceMarker(_ units: [UInt16], _ start: Int, _ end: Int) -> (char: UInt16, count: Int, range: NSRange)? {
        let first = skipSpaces(units, start, end, max: 3)
        guard first < end, units[first] == ch("`") || units[first] == ch("~") else { return nil }
        let char = units[first]
        var last = first
        while last < end, units[last] == char { last += 1 }
        guard last - first >= 3 else { return nil }
        if char == ch("`"), units[last..<end].contains(char) { return nil }
        return (char, last - first, NSRange(location: first, length: last - first))
    }

    private static func isClosingFence(_ units: [UInt16], _ start: Int, _ end: Int, _ open: Fence) -> Bool {
        let first = skipSpaces(units, start, end, max: 3)
        var last = first
        while last < end, units[last] == open.marker { last += 1 }
        guard last - first >= open.count else { return false }
        return units[last..<end].allSatisfy { $0 == space || $0 == tab }
    }

    // MARK: Block styles

    private static func styleLine(_ units: [UInt16], _ line: Line, level: Int, linked: inout [NSRange]) -> [Run] {
        let start = line.start
        let end = line.contentEnd
        switch line.kind {
        case .fenceOpen, .fenceClose:
            let whole = NSRange(location: start, length: line.end - start)
            var runs = [Run(range: whole, style: .codeBlock), Run(range: whole, style: .fence)]
            if let marker = fenceMarker(units, start, end) {
                runs.append(Run(range: marker.range, style: .syntax))
            } else if let closing = closingMarkerRange(units, start, end) {
                runs.append(Run(range: closing, style: .syntax))
            }
            return runs
        case .fenceBody:
            return line.end > start ? [Run(range: NSRange(location: start, length: line.end - start), style: .codeBlock)] : []
        case .normal:
            break
        }
        guard end > start else { return [] }
        if isThematicBreak(units, start, end) {
            return [Run(range: NSRange(location: start, length: end - start), style: .thematicBreak)]
        }

        var runs: [Run] = []
        var position = start

        var quoteStart: Int?
        var marker = skipSpaces(units, position, end, max: 3)
        while marker < end, units[marker] == ch(">") {
            quoteStart = quoteStart ?? marker
            position = marker + 1
            if position < end, units[position] == space { position += 1 }
            runs.append(Run(range: NSRange(location: marker, length: position - marker), style: .syntax))
            marker = skipSpaces(units, position, end, max: 3)
        }
        if let quoteStart {
            runs.insert(Run(range: NSRange(location: quoteStart, length: end - quoteStart), style: .blockquote), at: 0)
        }

        let hashes = skipSpaces(units, position, end, max: 3)
        var hashEnd = hashes
        while hashEnd < end, units[hashEnd] == ch("#") { hashEnd += 1 }
        let headingLevel = hashEnd - hashes
        if (1...6).contains(headingLevel), hashEnd == end || units[hashEnd] == space || units[hashEnd] == tab {
            runs.append(Run(range: NSRange(location: hashes, length: end - hashes), style: .heading(level: headingLevel)))
            var contentStart = hashEnd
            while contentStart < end, units[contentStart] == space || units[contentStart] == tab { contentStart += 1 }
            runs.append(Run(range: NSRange(location: hashes, length: contentStart - hashes), style: .syntax))
            runs.append(contentsOf: inlineRuns(units, from: hashEnd, to: end, linked: &linked))
            return runs
        }

        if let item = listItem(units, from: position, to: end, level: level) {
            runs.append(contentsOf: item.runs)
            position = item.contentStart
        }
        runs.append(contentsOf: inlineRuns(units, from: position, to: end, linked: &linked))
        return runs
    }

    private static func closingMarkerRange(_ units: [UInt16], _ start: Int, _ end: Int) -> NSRange? {
        let first = skipSpaces(units, start, end, max: 3)
        guard first < end, units[first] == ch("`") || units[first] == ch("~") else { return nil }
        var last = first
        while last < end, units[last] == units[first] { last += 1 }
        return NSRange(location: first, length: last - first)
    }

    private static func isThematicBreak(_ units: [UInt16], _ start: Int, _ end: Int) -> Bool {
        let first = skipSpaces(units, start, end, max: 3)
        guard first < end, [ch("-"), ch("*"), ch("_")].contains(units[first]) else { return false }
        let char = units[first]
        var count = 0
        for unit in units[first..<end] {
            if unit == char {
                count += 1
            } else if unit != space && unit != tab {
                return false
            }
        }
        return count >= 3
    }

    /// A bullet, numbered or task item's prefix, with the offset where the item's text begins.
    private static func listItem(_ units: [UInt16], from: Int, to end: Int, level: Int) -> (runs: [Run], contentStart: Int)? {
        var i = from
        while i < end, units[i] == space || units[i] == tab { i += 1 }
        let markerStart = i
        var kind = ListPrefix.Kind.bullet
        if i < end, [ch("-"), ch("+"), ch("*")].contains(units[i]) {
            i += 1
        } else {
            while i < end, i - markerStart < 9, units[i] >= ch("0"), units[i] <= ch("9") { i += 1 }
            guard i > markerStart, i < end, units[i] == ch(".") || units[i] == ch(")") else { return nil }
            i += 1
            kind = .numbered
        }
        guard i < end, units[i] == space || units[i] == tab else { return nil }
        let markerLength = i - markerStart
        var runs = [Run(range: NSRange(location: markerStart, length: markerLength), style: .listMarker)]
        while i < end, units[i] == space || units[i] == tab { i += 1 }

        if i + 3 <= end, units[i] == ch("["), units[i + 2] == ch("]"),
           [space, ch("x"), ch("X")].contains(units[i + 1]),
           i + 3 == end || units[i + 3] == space || units[i + 3] == tab {
            let checked = units[i + 1] != space
            runs.append(Run(range: NSRange(location: i, length: 3), style: .taskMarker(checked: checked)))
            kind = .task(checked: checked)
            i += 3
            while i < end, units[i] == space || units[i] == tab { i += 1 }
        }
        let prefix = ListPrefix(kind: kind, level: level, markerLength: markerLength)
        runs.append(Run(range: NSRange(location: markerStart, length: i - markerStart), style: .listPrefix(prefix)))
        return (runs, i)
    }

    /// The nesting level of each line's list item (0 for lines that aren't one), from the
    /// indentation of the items above: an item indented past the previous one is one level deeper.
    private static func listLevels(_ units: [UInt16], _ lines: [Line], upTo limit: Int) -> [Int] {
        var stack: [Int] = []
        return lines.map { line in
            guard line.kind == .normal, line.start < limit else { return 0 }
            let content = line.start..<line.contentEnd
            var firstNonBlank = line.start
            while firstNonBlank < line.contentEnd, units[firstNonBlank] == space || units[firstNonBlank] == tab { firstNonBlank += 1 }
            let indent = units[line.start..<firstNonBlank].reduce(0) { $0 + ($1 == tab ? 4 : 1) }
            guard firstNonBlank < line.contentEnd else { return 0 }
            let first = units[firstNonBlank]
            let startsLikeItem = first == ch("-") || first == ch("+") || first == ch("*") || (first >= ch("0") && first <= ch("9"))
            guard startsLikeItem, listItem(units, from: line.start, to: content.upperBound, level: 0) != nil else {
                if indent == 0 { stack.removeAll() }
                return 0
            }
            while let top = stack.last, top > indent { stack.removeLast() }
            if stack.last != indent { stack.append(indent) }
            return stack.count
        }
    }

    // MARK: Cursor reveal

    /// The whole lines whose syntax a view shows while `selection` is in them: every line the
    /// selection touches, widened to the whole fenced block when it touches one.
    static func revealRange(in units: [UInt16], selection: NSRange) -> NSRange {
        let all = lines(in: units)
        let selection = clamp(selection, to: units.count)
        guard var first = all.firstIndex(where: { $0.start <= selection.location && selection.location <= $0.contentEnd }) else {
            return NSRange(location: units.count, length: 0)
        }
        var last = first
        while last + 1 < all.count, all[last + 1].start < selection.upperBound { last += 1 }
        while first > 0, all[first].kind == .fenceBody || all[first].kind == .fenceClose { first -= 1 }
        while last + 1 < all.count, all[last].kind == .fenceOpen || all[last].kind == .fenceBody { last += 1 }
        return NSRange(location: all[first].start, length: all[last].end - all[first].start)
    }

    // MARK: Inline styles

    private struct EmphasisPass: Sendable {
        let regex: NSRegularExpression
        let delimiter: Int
        let styles: [Style]
    }

    private static let triggers: Set<UInt16> = Set("*_~`[<\\#:!".utf16)

    private static let emphasisPasses: [EmphasisPass] = [
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![*\\])\*\*\*(?=[^\s*])(.{1,1000}?)(?<=[^\s*])\*\*\*(?!\*)"#),
            delimiter: 3, styles: [.bold, .italic]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![\w\\])___(?=[^\s_])(.{1,1000}?)(?<=[^\s_])___(?![\w])"#),
            delimiter: 3, styles: [.bold, .italic]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![*\\])\*\*(?=[^\s*])(.{1,1000}?)(?<=[^\s*])\*\*(?!\*)"#),
            delimiter: 2, styles: [.bold]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![\w\\])__(?=[^\s_])(.{1,1000}?)(?<=[^\s_])__(?![\w])"#),
            delimiter: 2, styles: [.bold]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<!\\)~~(?=\S)(.{1,1000}?)(?<=\S)~~"#),
            delimiter: 2, styles: [.strikethrough]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![*\w\\])\*(?=[^\s*])(.{1,1000}?)(?<=[^\s*])\*(?!\*)"#),
            delimiter: 1, styles: [.italic]
        ),
        EmphasisPass(
            regex: try! NSRegularExpression(pattern: #"(?<![\w\\])_(?=[^\s_])(.{1,1000}?)(?<=[^\s_])_(?![\w])"#),
            delimiter: 1, styles: [.italic]
        ),
    ]
    private static let links = try! NSRegularExpression(pattern: #"(!?)\[([^\]\n]{0,1000})\]\(([^)\n]{0,2000})\)"#)
    private static let autolinks = try! NSRegularExpression(pattern: #"<[^>\s]{0,200}[:@][^>\s]{0,2000}>"#)
    private static let bareURLs = try! NSRegularExpression(pattern: #"(?<![\w@/])https?://[^\s<>\]\)]+"#)

    private static func inlineRuns(_ units: [UInt16], from: Int, to end: Int, linked: inout [NSRange]) -> [Run] {
        guard from < end else { return [] }
        let slice = Array(units[from..<end])
        guard slice.contains(where: triggers.contains) else { return [] }

        var runs: [Run] = []
        var work = slice
        var excludedFromTags: [NSRange] = []
        defer { linked.append(contentsOf: excludedFromTags.map { NSRange(location: $0.location + from, length: $0.length) }) }

        func add(_ range: NSRange, _ style: Style) {
            runs.append(Run(range: NSRange(location: range.location + from, length: range.length), style: style))
        }
        func blank(_ range: NSRange) {
            for i in range.location..<range.upperBound { work[i] = mask }
        }
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            let text = String(decoding: work, as: UTF16.self)
            return regex.matches(in: text, range: NSRange(location: 0, length: work.count))
        }

        for span in codeSpans(in: work) {
            add(span.range, .inlineCode)
            add(NSRange(location: span.range.location, length: span.tickCount), .syntax)
            add(NSRange(location: span.range.upperBound - span.tickCount, length: span.tickCount), .syntax)
            blank(span.range)
        }
        for escape in escapes(in: work) {
            add(NSRange(location: escape, length: 1), .syntax)
            blank(NSRange(location: escape, length: 2))
        }

        for token in imageTokens(in: work) {
            add(token.range, .image(token.id))
            excludedFromTags.append(token.range)
            blank(token.range)
        }

        for match in matches(links) {
            let text = match.range(at: 2)
            let opening = NSRange(location: match.range.location, length: text.location - match.range.location)
            let closing = NSRange(location: text.upperBound, length: match.range.upperBound - text.upperBound)
            add(opening, .syntax)
            if text.length > 0 { add(text, .link) }
            add(closing, .syntax)
            excludedFromTags.append(match.range)
            blank(opening)
            blank(closing)
        }
        for match in matches(autolinks) {
            let inner = NSRange(location: match.range.location + 1, length: match.range.length - 2)
            add(NSRange(location: match.range.location, length: 1), .syntax)
            add(inner, .link)
            add(NSRange(location: match.range.upperBound - 1, length: 1), .syntax)
            excludedFromTags.append(match.range)
            blank(match.range)
        }
        for match in matches(bareURLs) {
            var range = match.range
            while range.length > 1, ".,;:!?'\"".utf16.contains(work[range.upperBound - 1]) {
                range.length -= 1
            }
            add(range, .link)
            excludedFromTags.append(range)
            blank(range)
        }

        for pass in emphasisPasses {
            for match in matches(pass.regex) {
                let range = match.range
                for style in pass.styles { add(range, style) }
                let opening = NSRange(location: range.location, length: pass.delimiter)
                let closing = NSRange(location: range.upperBound - pass.delimiter, length: pass.delimiter)
                add(opening, .syntax)
                add(closing, .syntax)
                blank(opening)
                blank(closing)
            }
        }

        return runs
    }

    private static let imageMarker = Array("](img:".utf16)

    private static func imageTokens(in work: [UInt16]) -> [(range: NSRange, id: UUID)] {
        guard work.indices.contains(where: { work[$0...].starts(with: imageMarker) }) else { return [] }
        return ImageToken.matches(in: String(decoding: work, as: UTF16.self))
    }

    /// Backtick spans: a run of backticks up to the next run of the same length on the line.
    private static func codeSpans(in work: [UInt16]) -> [(range: NSRange, tickCount: Int)] {
        var runs: [(start: Int, length: Int)] = []
        var i = 0
        while i < work.count {
            guard work[i] == ch("`") else { i += 1; continue }
            var end = i
            while end < work.count, work[end] == ch("`") { end += 1 }
            runs.append((i, end - i))
            i = end
        }
        var nextByLength: [Int: [Int]] = [:]
        for (index, run) in runs.enumerated() { nextByLength[run.length, default: []].append(index) }
        var cursor: [Int: Int] = [:]

        var spans: [(range: NSRange, tickCount: Int)] = []
        var index = 0
        while index < runs.count {
            let open = runs[index]
            let candidates = nextByLength[open.length]!
            var position = cursor[open.length] ?? 0
            while position < candidates.count, candidates[position] <= index { position += 1 }
            cursor[open.length] = position
            guard position < candidates.count else { index += 1; continue }
            let closeIndex = candidates[position]
            let close = runs[closeIndex]
            spans.append((NSRange(location: open.start, length: close.start + close.length - open.start), open.length))
            index = closeIndex + 1
        }
        return spans
    }

    /// Offsets of backslashes that escape the ASCII punctuation after them.
    private static func escapes(in work: [UInt16]) -> [Int] {
        var result: [Int] = []
        var i = 0
        while i + 1 < work.count {
            if work[i] == ch("\\"), isASCIIPunctuation(work[i + 1]) {
                result.append(i)
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    /// The tags `TagParser` extracts, restricted to the normal lines among `lines` (contiguous)
    /// and minus those inside links or images and backslash-escaped ones. `TagParser` accepts
    /// ``` and ~~~ anywhere, not just at a line start, so it runs on the lines' text, led by the
    /// marker of any fence it pairs up that is still open where the lines begin.
    private static func tagRuns(_ units: [UInt16], lines: [Line], linked: [NSRange]) -> [Run] {
        guard let first = lines.first, let last = lines.last,
              units[first.start..<last.end].contains(ch("#")) else { return [] }
        let lead = openFenceMarker(units, before: first.start)
        let text = String(decoding: lead + units[first.start..<last.end], as: UTF16.self)
        let shift = first.start - lead.count
        return TagParser.matches(in: text).compactMap { match in
            let range = NSRange(location: match.range.location + shift, length: match.range.length)
            guard lines.contains(where: { $0.kind == .normal && $0.start <= range.location && range.location < $0.contentEnd }),
                  !linked.contains(where: { NSIntersectionRange($0, range).length > 0 })
            else { return nil }
            var slashes = 0
            var i = range.location - 1
            while i >= 0, units[i] == ch("\\") {
                slashes += 1
                i -= 1
            }
            return slashes % 2 == 0 ? Run(range: range, style: .tag) : nil
        }
    }

    /// The marker of the ``` or ~~~ fence, paired the way `TagParser` pairs them, that is open at `offset`.
    private static func openFenceMarker(_ units: [UInt16], before offset: Int) -> [UInt16] {
        func tripleAt(_ i: Int) -> UInt16? {
            guard i + 2 < units.count else { return nil }
            let unit = units[i]
            guard unit == 0x60 || unit == 0x7E, units[i + 1] == unit, units[i + 2] == unit else { return nil }
            return unit
        }
        var i = 0
        while i < offset {
            while i < offset, tripleAt(i) == nil { i += 1 }
            guard i < offset, let marker = tripleAt(i) else { return [] }
            var close = i + 3
            while close < units.count, tripleAt(close) != marker { close += 1 }
            if close >= units.count || offset < close + 3 { return [marker, marker, marker] }
            i = close + 3
        }
        return []
    }
}
