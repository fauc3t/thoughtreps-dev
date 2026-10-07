import UIKit

/// An image token shown as a thumbnail over its (invisible) text.
struct DisplayedImage {
    var range: NSRange
    let id: UUID
    let image: UIImage
    let size: CGSize
}

/// A bullet or task prefix drawn as a glyph over its (invisible) text, one unit for the caret.
struct DisplayedMarker {
    var range: NSRange
    let prefix: MarkdownStyler.ListPrefix
    /// Nil for a numbered prefix, which stays visible text.
    let glyph: UIImage?
    let tint: UIColor
    let width: CGFloat

    var isTask: Bool {
        if case .task = prefix.kind { return true }
        return false
    }
}

struct AppliedStyle {
    var images: [DisplayedImage] = []
    var markers: [DisplayedMarker] = []
}

/// Turns `MarkdownStyler` runs into text attributes. The look follows `Theme.thoughtReps`:
/// heading sizes as multiples of the Dynamic Type body size, semibold bold, monospaced code,
/// bullets as `•` `◦` `▪` and tasks as checkbox symbols. Syntax is faded on the lines in `reveal`
/// and hidden (zero width, text unchanged) elsewhere.
@MainActor
final class MarkdownStyleApplier {
    static let maxImageHeight: CGFloat = 160
    private static let collapsedFenceHeight: CGFloat = 4

    private struct Look: OptionSet, Hashable {
        let rawValue: UInt32

        static let bold = Look(rawValue: 1 << 0)
        static let italic = Look(rawValue: 1 << 1)
        static let strikethrough = Look(rawValue: 1 << 2)
        static let monospaced = Look(rawValue: 1 << 3)
        static let inlineCode = Look(rawValue: 1 << 4)
        static let codeBlock = Look(rawValue: 1 << 5)
        static let quote = Look(rawValue: 1 << 6)
        static let syntax = Look(rawValue: 1 << 7)
        static let link = Look(rawValue: 1 << 8)
        static let tag = Look(rawValue: 1 << 9)
        static let hidden = Look(rawValue: 1 << 10)
        static let digits = Look(rawValue: 1 << 11)

        static let headingShift: UInt32 = 16
        static let headingMask: UInt32 = 0b111 << headingShift

        var heading: Int { Int((rawValue & Self.headingMask) >> Self.headingShift) }

        mutating func setHeading(_ level: Int) {
            self = Look(rawValue: (rawValue & ~Self.headingMask) | (UInt32(level) << Self.headingShift))
        }
    }

    let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
    private var fonts: [Look: UIFont] = [:]
    private var glyphs: [String: UIImage] = [:]

    /// Width reserved for a bullet or checkbox, like the renderer's 1.5 em marker column.
    var markerWidth: CGFloat { bodySize * 1.5 }

    var baseFont: UIFont { font(for: []) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: UIColor.label]
    }

    /// Restyles `region` (line-aligned) from `runs`. An image token shows as a thumbnail only when
    /// it is alone on its line and `image` can resolve it.
    func apply(
        runs: [MarkdownStyler.Run],
        region: NSRange,
        units: [UInt16],
        to storage: NSTextStorage,
        availableWidth: CGFloat,
        reveal: NSRange,
        image: (UUID) -> UIImage?
    ) -> AppliedStyle {
        guard region.length > 0 else { return AppliedStyle() }
        var looks = [Look](repeating: [], count: region.length)
        var applied = AppliedStyle()
        var collapsedFences: [NSRange] = []
        var hangingIndents: [(range: NSRange, prefix: MarkdownStyler.ListPrefix)] = []

        for run in runs {
            let clipped = NSIntersectionRange(run.range, region)
            guard clipped.length > 0 else { continue }
            let low = clipped.location - region.location
            let span = low..<(low + clipped.length)
            let revealed = NSLocationInRange(run.range.location, reveal)
            switch run.style {
            case let .image(id):
                if let thumbnail = image(id), isAloneOnLine(run.range, in: units) {
                    applied.images.append(DisplayedImage(
                        range: run.range,
                        id: id,
                        image: thumbnail,
                        size: Self.displaySize(of: thumbnail, availableWidth: availableWidth)
                    ))
                    for i in span { looks[i].insert(.hidden) }
                } else {
                    for i in span { looks[i].insert(.syntax) }
                }
            case let .heading(level):
                for i in span { looks[i].setHeading(level) }
            case .syntax:
                for i in span { looks[i].insert(revealed ? .syntax : .hidden) }
            case .fence:
                if !revealed {
                    for i in span { looks[i].insert(.hidden) }
                    collapsedFences.append(run.range)
                }
            case let .listPrefix(prefix):
                hangingIndents.append((run.range, prefix))
                if prefix.kind == .numbered {
                    applied.markers.append(DisplayedMarker(range: run.range, prefix: prefix, glyph: nil, tint: .secondaryLabel, width: 0))
                    let marker = NSIntersectionRange(NSRange(location: run.range.location, length: prefix.markerLength), region)
                    for i in (marker.location - region.location)..<(marker.upperBound - region.location) { looks[i].insert(.digits) }
                } else {
                    for i in span { looks[i].insert(.hidden) }
                    applied.markers.append(marker(for: prefix, range: run.range))
                }
            default:
                let flags = Self.flags(for: run.style)
                for i in span { looks[i].formUnion(flags) }
            }
        }

        storage.beginEditing()
        var start = 0
        while start < looks.count {
            var end = start + 1
            while end < looks.count, looks[end] == looks[start] { end += 1 }
            storage.setAttributes(
                attributes(for: looks[start]),
                range: NSRange(location: region.location + start, length: end - start)
            )
            start = end
        }
        for item in applied.images {
            reserveSpace(for: item, in: storage, units: units)
        }
        for item in applied.markers where item.glyph != nil {
            reserveSpace(for: item, in: storage)
        }
        for entry in hangingIndents {
            applyHangingIndent(entry.prefix, range: entry.range, in: storage, units: units)
        }
        for fence in collapsedFences {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = Self.collapsedFenceHeight
            paragraph.maximumLineHeight = Self.collapsedFenceHeight
            storage.addAttribute(.paragraphStyle, value: paragraph, range: fence)
        }
        storage.endEditing()
        return applied
    }

    static func displaySize(of image: UIImage, availableWidth: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(availableWidth / size.width, maxImageHeight / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private static func flags(for style: MarkdownStyler.Style) -> Look {
        switch style {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .inlineCode: [.monospaced, .inlineCode]
        case .codeBlock: [.monospaced, .codeBlock]
        case .blockquote: .quote
        case .listMarker, .thematicBreak: .syntax
        case let .taskMarker(checked): checked ? .link : .syntax
        case .link: .link
        case .tag: .tag
        case .heading, .image, .syntax, .fence, .listPrefix: []
        }
    }

    private func marker(for prefix: MarkdownStyler.ListPrefix, range: NSRange) -> DisplayedMarker {
        let glyph: UIImage
        var tint = UIColor.secondaryLabel
        switch prefix.kind {
        case .bullet, .numbered:
            glyph = bulletGlyph(level: prefix.level)
        case let .task(checked):
            glyph = checkboxGlyph(checked: checked)
            if checked { tint = .tintColor }
        }
        return DisplayedMarker(range: range, prefix: prefix, glyph: glyph, tint: tint, width: markerWidth)
    }

    private func bulletGlyph(level: Int) -> UIImage {
        let text = ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(max(level, 1), 3) - 1]
        if let cached = glyphs[text] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: bodySize), .foregroundColor: UIColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysTemplate)
        glyphs[text] = image
        return image
    }

    private func checkboxGlyph(checked: Bool) -> UIImage {
        let name = checked ? "checkmark.square.fill" : "square"
        if let cached = glyphs[name] { return cached }
        let configuration = UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: bodySize))
        let image = (UIImage(systemName: name, withConfiguration: configuration) ?? UIImage()).withRenderingMode(.alwaysTemplate)
        glyphs[name] = image
        return image
    }

    /// Wrapped lines of an item line up with its text: the indentation plus the marker's width.
    /// Spreads the hidden prefix over the marker's width. Its last character (the space) keeps the
    /// body font, still invisible, so an empty item's line and caret are full height rather than the
    /// hidden font's sliver. Trailing kern is dropped at a line end, so the width goes on the others.
    private func reserveSpace(for item: DisplayedMarker, in storage: NSTextStorage) {
        guard item.range.length > 0 else { return }
        let last = NSRange(location: item.range.upperBound - 1, length: 1)
        storage.addAttribute(.font, value: baseFont, range: last)
        let lastWidth = storage.attributedSubstring(from: last).size().width
        let rest = NSRange(location: item.range.location, length: item.range.length - 1)
        guard rest.length > 0 else { return }
        storage.addAttribute(.kern, value: (item.width - lastWidth) / CGFloat(rest.length), range: rest)
    }

    private func applyHangingIndent(
        _ prefix: MarkdownStyler.ListPrefix,
        range: NSRange,
        in storage: NSTextStorage,
        units: [UInt16]
    ) {
        let line = MarkdownStyler.lineAlignedRange(in: units, covering: NSRange(location: range.location, length: 0))
        let indentText = String(decoding: units[line.location..<range.location], as: UTF16.self)
        let indent = (indentText as NSString).size(withAttributes: [.font: baseFont]).width
        var markerAdvance = markerWidth
        if prefix.kind == .numbered {
            let text = String(decoding: units[range.location..<range.upperBound], as: UTF16.self)
            markerAdvance = (text as NSString).size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)]).width
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = (indent + markerAdvance).rounded(.up)
        storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
    }

    private func isAloneOnLine(_ range: NSRange, in units: [UInt16]) -> Bool {
        let before = range.location == 0 || units[range.location - 1] == 0x0A
        let after = range.upperBound >= units.count || units[range.upperBound] == 0x0A
        return before && after
    }

    /// Spreads the token's hidden characters over the thumbnail's width, so the caret before and
    /// after the token sit at the thumbnail's edges, and fixes the line's height to it.
    private func reserveSpace(for item: DisplayedImage, in storage: NSTextStorage, units: [UInt16]) {
        storage.addAttribute(.kern, value: item.size.width / CGFloat(max(item.range.length, 1)), range: item.range)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = item.size.height
        paragraph.maximumLineHeight = item.size.height
        var lineEnd = item.range.upperBound
        if lineEnd < units.count, units[lineEnd] == 0x0A { lineEnd += 1 }
        storage.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: item.range.location, length: lineEnd - item.range.location)
        )
    }

    private func attributes(for look: Look) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(for: look), .foregroundColor: color(for: look)]
        if look.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if look.contains(.inlineCode) || look.contains(.codeBlock) {
            attributes[.backgroundColor] = UIColor.secondarySystemFill
        }
        return attributes
    }

    private func color(for look: Look) -> UIColor {
        if look.contains(.hidden) { return .clear }
        if look.contains(.syntax) { return .secondaryLabel }
        if look.contains(.link) || look.contains(.tag) { return .tintColor }
        if look.contains(.quote) { return .secondaryLabel }
        return .label
    }

    private func font(for look: Look) -> UIFont {
        if let cached = fonts[look] { return cached }
        let font = look.contains(.hidden) ? UIFont.systemFont(ofSize: 0.01) : makeFont(for: look)
        fonts[look] = font
        return font
    }

    private func makeFont(for look: Look) -> UIFont {
        var scale: CGFloat = 1
        var weight = UIFont.Weight.regular
        switch look.heading {
        case 1: (scale, weight) = (1.65, .bold)
        case 2: (scale, weight) = (1.3, .bold)
        case 3: (scale, weight) = (1.18, .semibold)
        case 4...6: weight = .semibold
        default: break
        }
        if look.contains(.bold), weight.rawValue < UIFont.Weight.semibold.rawValue { weight = .semibold }

        let monospaced = look.contains(.monospaced)
        let size = bodySize * scale * (monospaced ? 0.94 : 1)
        let base: UIFont
        if monospaced {
            base = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        } else if look.contains(.digits) {
            base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        } else {
            base = UIFont.systemFont(ofSize: size, weight: weight)
        }
        guard look.contains(.italic),
              let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic))
        else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
