import SwiftUI
import UIKit

/// The editor's Markdown body: a `UITextView` (TextKit 2) whose text is the plain Markdown
/// string, styled live by `MarkdownStyler`. Syntax is faded on the lines the selection touches and
/// hidden (zero width, text untouched) on the rest. Image tokens show as thumbnails, and bullet and
/// task prefixes as glyphs; each selects and deletes as one unit.
///
/// SwiftUI's rich `TextEditor` needs iOS 26, so this wraps UIKit and mirrors `TextEditor`'s
/// `text` and `selection` bindings. The keyboard accessory is hosted here because SwiftUI's
/// `.keyboard` toolbar doesn't reach a wrapped text view.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    let imageData: (UUID) -> Data?
    let accessory: AnyView
    /// Changing this clears the undo history after the update that applies the text, so loading a thought isn't undoable.
    let undoResetToken: Int
    /// The height the text needs, at least `minHeight`. The view never scrolls and has no cap, so the
    /// Form is the only scroller; the cost is TextKit 2 laying out the fragments in the frame.
    @Binding var height: CGFloat
    /// The least height; a text block uses less than the body.
    var minHeight = MarkdownTextView.minHeight
    /// Grey text shown while the field is empty.
    var placeholder: String?

    static let minHeight: CGFloat = 220

    /// A height to start from before the view has been laid out, so opening a long thought doesn't
    /// visibly grow. Short text is measured at the body font over `width`; long text is estimated
    /// from its paragraph lengths and an average character width, which stays fast at any length.
    static func estimatedHeight(for text: String, width: CGFloat) -> CGFloat {
        guard width > 0 else { return minHeight }
        let font = UIFont.preferredFont(forTextStyle: .body)
        if text.utf16.count <= 8_000 {
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
            return max(minHeight, ceil(measured) + 16)
        }
        let charactersPerLine = max(1, Int(width / (font.pointSize * 0.5)))
        var lines = 0
        var paragraph = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                lines += max(1, (paragraph + charactersPerLine - 1) / charactersPerLine)
                paragraph = 0
            } else {
                paragraph += 1
            }
        }
        lines += max(1, (paragraph + charactersPerLine - 1) / charactersPerLine)
        return max(minHeight, ceil(CGFloat(lines) * font.lineHeight) + 16)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> StyledTextView {
        let view = StyledTextView(usingTextLayoutManager: true)
        context.coordinator.attach(to: view, accessory: accessory)
        return view
    }

    func updateUIView(_ view: StyledTextView, context: Context) {
        context.coordinator.update(self)
    }

    // A non-scrolling text view's intrinsic width is its longest unwrapped line, so take the offered
    // width instead; the text then wraps and `height` is measured at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: StyledTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: max(height, minHeight))
    }

    static func dismantleUIView(_ view: StyledTextView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

final class StyledTextView: UITextView {
    var onLayout: (() -> Void)?
    /// Ranges backspace deletes whole: atomic ones from anywhere inside, the others only from their end.
    var deleteUnits: () -> [(range: NSRange, atomic: Bool)] = { [] }
    var onCommitMarkedText: (() -> Void)?
    var isCheckboxAt: ((CGPoint) -> Bool)?
    weak var checkboxTap: UITapGestureRecognizer?

    // A touch on a task's checkbox toggles it instead of reaching the text view's own recognizers,
    // so it neither focuses the view nor moves the caret. Scrolling still starts there.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let onCheckbox = isCheckboxAt?(gestureRecognizer.location(in: self)) ?? false
        if gestureRecognizer === checkboxTap { return onCheckbox }
        if onCheckbox, !(gestureRecognizer is UIPanGestureRecognizer) { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func unmarkText() {
        let wasMarked = markedTextRange != nil
        super.unmarkText()
        if wasMarked { onCommitMarkedText?() }
    }

    // Backspace after (or in) an image token or bullet or task prefix deletes the whole unit;
    // after a numbered prefix it deletes the prefix, leaving the indentation.
    override func deleteBackward() {
        let caret = selectedRange
        if caret.length == 0,
           let unit = deleteUnits().first(where: {
               $0.atomic ? ($0.range.location < caret.location && caret.location <= $0.range.upperBound) : caret.location == $0.range.upperBound
           }) {
            selectedRange = unit.range
        }
        super.deleteBackward()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    // The storage carries hidden-text attributes for image tokens, so copy plain Markdown only.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        UIPasteboard.general.string = (text as NSString).substring(with: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, let range = selectedTextRange else { return }
        copy(sender)
        replace(range, withText: "")
    }
}

/// Keyboard accessory that floats its SwiftUI content in a glass pill above the keyboard, like
/// SwiftUI's `.keyboard` toolbar.
@MainActor
private final class AccessoryBar: UIInputView {
    static let pillHeight: CGFloat = 48
    static let margin: CGFloat = 8
    private let content: UIView & UIContentView

    init(rootView: AnyView) {
        content = Self.configuration(rootView).makeContentView()
        let height = Self.pillHeight + 2 * Self.margin
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        content.backgroundColor = .clear
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let heightConstraint = heightAnchor.constraint(equalToConstant: height)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ rootView: AnyView) {
        content.configuration = Self.configuration(rootView)
    }

    private static func configuration(_ rootView: AnyView) -> UIHostingConfiguration<AccessoryPill, EmptyView> {
        UIHostingConfiguration { AccessoryPill(content: rootView) }
            .margins(.all, 0)
    }
}

/// The accessory's content in a capsule: Liquid Glass on iOS 26, a material before it.
private struct AccessoryPill: View {
    let content: AnyView

    var body: some View {
        let pill = content
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: AccessoryBar.pillHeight, maxHeight: AccessoryBar.pillHeight)
            .clipShape(Capsule())
        Group {
            if #available(iOS 26, *) {
                pill.glassEffect(.regular, in: .capsule)
            } else {
                pill
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
        }
        .padding(AccessoryBar.margin)
    }
}

extension MarkdownTextView {
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var parent: MarkdownTextView
        private weak var textView: StyledTextView?
        private var accessoryBar: AccessoryBar?
        private var applier = MarkdownStyleApplier()

        private var displayed: [DisplayedImage] = []
        private var markers: [DisplayedMarker] = []
        private var imageCache: [UUID: UIImage] = [:]
        private var overlays: [UIImageView] = []
        private var markerViews: [UIImageView] = []
        /// Each task's checkbox hit area: its glyph's width plus a margin, over its own line fragment only.
        private var checkboxTargets: [(range: NSRange, frame: CGRect)] = []
        private var lastWidth: CGFloat = 0
        private var reportedHeight: CGFloat = 0
        private var measuredWidth: CGFloat = 0
        private var measuredUsage: CGFloat = 0
        private var measuredHeight: CGFloat = 0
        private var needsCaretScroll = false
        private weak var observedScrollView: UIScrollView?
        private var scrollObservation: NSKeyValueObservation?
        private var accessibilitySignature: [String] = []

        /// The whole lines whose syntax is shown: the lines the selection touches.
        private(set) var revealed = NSRange(location: 0, length: 0)
        #if DEBUG
        /// How many times the whole text was measured for height.
        private(set) var fullMeasureCount = 0
        /// The last few regions restyled, newest last.
        private(set) var recentlyStyled: [NSRange] = []
        #endif

        /// Set while this class changes the text view itself, so the delegate callbacks it causes are ignored.
        private var isApplying = false
        /// Set while an edit touching an atomic unit is redone over the whole unit.
        private var isExpanding = false
        /// Between a text change being allowed and `textViewDidChange` publishing it.
        private var inChange = false
        private var changeHandled = false
        /// The edited range in current coordinates, accumulated until the text is next restyled.
        private var dirty: NSRange?
        private var dirtyTouchesFence = false
        /// The list signature of the lines the first pending edit touched, before it.
        private var dirtyListSignature: [Int]?
        private var lastSelection = NSRange(location: 0, length: 0)
        private var lastUndoResetToken = 0
        private var hasSynced = false
        /// The text last published to or applied from the owner, so an update can tell nothing changed without copying the view's string.
        private var knownText = ""
        /// Whether the owner wanted focus at the previous update; nil before the first, which never takes focus.
        private var wasFocused: Bool?
        private var focusRequested = false
        #if DEBUG
        /// Updates received by all text views, for tests that count the work a keystroke causes.
        nonisolated(unsafe) static var updateCount = 0
        #endif
        private var placeholderLabel: UILabel?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func attach(to view: StyledTextView, accessory: AnyView) {
            textView = view
            view.delegate = self
            view.backgroundColor = .clear
            view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            view.textContainer.lineFragmentPadding = 0
            view.isScrollEnabled = false
            // Smart delete ate the blank lines around a deleted image token. Autocorrect and the double-space period are separate.
            view.smartInsertDeleteType = .no
            view.font = applier.baseFont
            view.typingAttributes = applier.baseAttributes
            view.accessibilityLabel = parent.accessibilityLabel
            view.onLayout = { [weak self] in self?.viewDidLayout() }
            view.onCommitMarkedText = { [weak self] in self?.restyleDirty() }
            view.deleteUnits = { [weak self] in self?.deleteUnits ?? [] }
            view.isCheckboxAt = { [weak self] point in self?.checkboxTarget(at: point) != nil }
            let tap = UITapGestureRecognizer(target: self, action: #selector(checkboxTapped(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)
            view.checkboxTap = tap
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification, object: nil
            )
            view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: StyledTextView, _) in
                MainActor.assumeIsolated { self?.contentSizeCategoryChanged() }
            }
            let bar = AccessoryBar(rootView: accessory)
            accessoryBar = bar
            view.inputAccessoryView = bar
            if let placeholder = parent.placeholder {
                let label = UILabel()
                label.text = placeholder
                label.font = applier.baseFont
                label.textColor = .tertiaryLabel
                label.isAccessibilityElement = false
                label.isUserInteractionEnabled = false
                view.addSubview(label)
                placeholderLabel = label
            }
        }

        var displayedImageCount: Int { displayed.count }
        var displayedMarkers: [DisplayedMarker] { markers }

        func update(_ new: MarkdownTextView) {
            parent = new
            guard let view = textView else { return }
            #if DEBUG
            Self.updateCount += 1
            #endif
            view.accessibilityLabel = new.accessibilityLabel
            // Only the focused field's accessory is on screen; the others refresh when they next take focus.
            if view.isFirstResponder || !hasSynced { accessoryBar?.update(new.accessory) }
            if new.text != knownText {
                replaceText(with: new.text, notify: false)
                knownText = new.text
            }
            syncSelection(in: view)
            if !hasSynced {
                hasSynced = true
                view.undoManager?.removeAllActions()
            }
            if new.undoResetToken != lastUndoResetToken {
                lastUndoResetToken = new.undoResetToken
                view.undoManager?.removeAllActions()
            }
            updateFocus(wants: new.isFocused, view: view)
        }

        /// A view only takes first responder when focus is asked for while it exists: a stale focus value
        /// that happens to match, as when a scrolled-away row is rebuilt, must not bring the keyboard back.
        private func updateFocus(wants: Bool, view: StyledTextView) {
            if let wasFocused, wants, !wasFocused { focusRequested = true }
            if !wants { focusRequested = false }
            wasFocused = wants
            if focusRequested {
                if view.isFirstResponder {
                    focusRequested = false
                } else {
                    DispatchQueue.main.async { view.becomeFirstResponder() }
                }
            } else if !wants, view.isFirstResponder {
                DispatchQueue.main.async { view.resignFirstResponder() }
            }
        }

        /// The row is going away: it must not leave the focus on a field that no longer exists.
        func dismantle() {
            let isFocused = parent.$isFocused
            DispatchQueue.main.async {
                if isFocused.wrappedValue { isFocused.wrappedValue = false }
            }
        }

        // MARK: Delegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
            requestCaretScroll()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            needsCaretScroll = false
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            if isExpanding || isApplying { return true }
            if textView.markedTextRange == nil, let expanded = expandedOverUnits(range, replacement: replacement), expanded != range {
                replaceExpanded(expanded, with: replacement, in: textView)
                return false
            }
            beginEdit(range, newLength: replacement.utf16.count)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            changeHandled = true
            let wasAnnounced = inChange
            inChange = false
            guard !isApplying else { return }
            publish(textView)
            requestCaretScroll()
            guard textView.markedTextRange == nil else {
                if !wasAnnounced { dirty = NSRange(location: 0, length: textView.textStorage.length) }
                return
            }
            restyleDirty(wasAnnounced: wasAnnounced)
        }

        /// Restyles what edits since the last restyle touched. A change that was never announced through
        /// `shouldChangeTextIn` (UIKit's own undo and redo, dictation) can't be located, so the whole text is restyled.
        fileprivate func restyleDirty(wasAnnounced: Bool = true) {
            let units = currentUnits()
            let edited = wasAnnounced ? dirty : NSRange(location: 0, length: units.count)
            let fenceChanged = dirtyTouchesFence
            let listBefore = dirtyListSignature
            dirtyListSignature = nil
            dirty = nil
            dirtyTouchesFence = false
            guard let edited else { return }
            restyle(edited: edited, fenceChanged: fenceChanged, listBefore: listBefore, units: units)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying, !isExpanding else { return }
            if textView.markedTextRange == nil {
                snapToAtomicBoundaries(in: textView)
                if !inChange { revealSelectionLines(in: textView) }
            }
            lastSelection = textView.selectedRange
            if !inChange {
                publishSelection(textView)
                if textView.isFirstResponder, textView.selectedRange.length == 0 { requestCaretScroll() }
            }
        }

        // MARK: Text and selection sync

        private func publish(_ view: UITextView) {
            let text = view.text ?? ""
            knownText = text
            parent.text = text
            parent.selection = Self.selection(view.selectedRange, in: text)
        }

        private func publishSelection(_ view: UITextView) {
            parent.selection = Self.selection(view.selectedRange, in: view.text ?? "")
        }

        private static func selection(_ range: NSRange, in text: String) -> TextSelection {
            let lower = String.Index(utf16Offset: range.location, in: text)
            guard range.length > 0 else { return TextSelection(insertionPoint: lower) }
            return TextSelection(range: lower..<String.Index(utf16Offset: range.upperBound, in: text))
        }

        private func syncSelection(in view: UITextView) {
            guard let selection = parent.selection, case let .selection(range) = selection.indices else { return }
            let text = parent.text
            let length = text.utf16.count
            let lower = min(range.lowerBound.utf16Offset(in: text), length)
            let upper = min(max(range.upperBound.utf16Offset(in: text), lower), length)
            let target = NSRange(location: lower, length: upper - lower)
            guard target != view.selectedRange else { return }
            isApplying = true
            view.selectedRange = target
            isApplying = false
            lastSelection = target
            revealSelectionLines(in: view)
        }

        /// Applies text that changed outside the view (format bar, list continuation, tag
        /// suggestions, image insertion) as the smallest replacement, and makes it undoable.
        private func replaceText(with new: String, notify: Bool, selection: NSRange? = nil) {
            let oldUnits = currentUnits()
            let newUnits = Array(new.utf16)

            var prefix = 0
            let limit = min(oldUnits.count, newUnits.count)
            while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
            if prefix > 0, UTF16.isLeadSurrogate(newUnits[prefix - 1]) { prefix -= 1 }
            var suffix = 0
            while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
            if suffix > 0, UTF16.isTrailSurrogate(newUnits[newUnits.count - suffix]) { suffix -= 1 }

            let removed = NSRange(location: prefix, length: oldUnits.count - prefix - suffix)
            let replacement = String(decoding: newUnits[prefix..<(newUnits.count - suffix)], as: UTF16.self)
            replace(removed, in: oldUnits, with: replacement, notify: notify, selection: selection)
        }

        /// Replaces `range` of the current text and registers the inverse replacement for undo,
        /// holding only the changed text rather than the whole body.
        private func replace(_ range: NSRange, in oldUnits: [UInt16], with replacement: String, notify: Bool, selection: NSRange?) {
            guard let view = textView else { return }
            let inserted = NSRange(location: range.location, length: replacement.utf16.count)
            let oldSelection = view.selectedRange
            let removedText = String(decoding: oldUnits[range.location..<range.upperBound], as: UTF16.self)
            let touchedLines = MarkdownStyler.lineAlignedRange(in: oldUnits, covering: range)
            let touchedUnits = Array(oldUnits[touchedLines.location..<touchedLines.upperBound])
            let fenceChanged = MarkdownStyler.hasFenceMarker(touchedUnits)
            let listBefore = MarkdownStyler.listSignature(of: touchedUnits)

            view.undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.undoReplacement(of: inserted, with: removedText, selection: oldSelection)
                }
            }

            isApplying = true
            shiftTracked(edit: range, newLength: inserted.length)
            view.textStorage.replaceCharacters(in: range, with: replacement)
            let units = currentUnits()

            let target = selection ?? NSRange(
                location: Self.shifted(oldSelection.location, edit: range, newLength: inserted.length),
                length: 0
            )
            let location = min(target.location, units.count)
            view.selectedRange = NSRange(location: location, length: min(target.length, units.count - location))
            lastSelection = view.selectedRange
            restyle(edited: inserted, fenceChanged: fenceChanged, listBefore: listBefore, units: units)
            isApplying = false
            if notify { publish(view) }
            if view.isFirstResponder { requestCaretScroll() }
        }

        private func undoReplacement(of range: NSRange, with text: String, selection: NSRange) {
            let units = currentUnits()
            guard range.upperBound <= units.count else { return }
            replace(range, in: units, with: text, notify: true, selection: selection)
        }

        // MARK: Restyling

        private func currentUnits() -> [UInt16] {
            guard let storage = textView?.textStorage else { return [] }
            let string = storage.mutableString
            var units = [UInt16](repeating: 0, count: string.length)
            string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
            return units
        }

        /// Restyles the lines an edit touched, plus the lines whose syntax is shown or hidden because the
        /// selection moved: the ones it left and the ones it reached, never the lines between.
        private func restyle(edited: NSRange?, fenceChanged: Bool, listBefore: [Int]? = nil, units: [UInt16]) {
            guard let view = textView else { return }
            let old = revealed
            let new = MarkdownStyler.revealRange(in: units, selection: view.selectedRange)
            revealed = new

            var regions: [NSRange] = []
            if let edited {
                var region = MarkdownStyler.restyleRange(in: units, edited: edited, fenceChanged: fenceChanged)
                if let listBefore, listBefore != MarkdownStyler.listSignature(of: Array(units[region.location..<region.upperBound])) {
                    region = MarkdownStyler.restyleRange(in: units, edited: edited, fenceChanged: fenceChanged, listChanged: true)
                }
                regions.append(region)
            }
            if old != new {
                regions.append(NSIntersectionRange(old, NSRange(location: 0, length: units.count)))
                regions.append(new)
            }
            for region in Self.merged(regions) { style(region, units: units) }
        }

        private static func merged(_ regions: [NSRange]) -> [NSRange] {
            var result: [NSRange] = []
            for region in regions.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
                if let last = result.last, region.location <= last.upperBound {
                    result[result.count - 1] = NSUnionRange(last, region)
                } else {
                    result.append(region)
                }
            }
            return result
        }

        /// Moves which lines show their syntax to follow the selection. A caret that lands inside
        /// syntax that was hidden moves to its nearer edge, so it ends up next to the word it was aimed at.
        private func revealSelectionLines(in view: UITextView) {
            let units = currentUnits()
            let new = MarkdownStyler.revealRange(in: units, selection: view.selectedRange)
            guard new != revealed else { return }

            let caret = view.selectedRange
            if caret.length == 0, !NSLocationInRange(caret.location, revealed) || revealed.length == 0 {
                let syntax = MarkdownStyler.runs(in: units, range: NSRange(location: caret.location, length: 0))
                    .first { $0.style == .syntax && caret.location > $0.range.location && caret.location < $0.range.upperBound }
                if let syntax {
                    let step = abs(caret.location - lastSelection.location) == 1
                    let forward = step
                        ? caret.location > lastSelection.location
                        : caret.location - syntax.range.location >= syntax.range.upperBound - caret.location
                    isApplying = true
                    view.selectedRange = NSRange(location: forward ? syntax.range.upperBound : syntax.range.location, length: 0)
                    isApplying = false
                }
            }
            restyle(edited: nil, fenceChanged: false, units: units)
        }

        private func style(_ region: NSRange, units: [UInt16]) {
            guard let view = textView else { return }
            let wasApplying = isApplying
            isApplying = true
            defer { isApplying = wasApplying }

            #if DEBUG
            recentlyStyled = Array((recentlyStyled + [region]).suffix(8))
            #endif
            let runs = MarkdownStyler.runs(in: units, range: region)
            displayed.removeAll { NSIntersectionRange($0.range, region).length > 0 }
            markers.removeAll { NSIntersectionRange($0.range, region).length > 0 }
            let applied = applier.apply(
                runs: runs,
                region: region,
                units: units,
                to: view.textStorage,
                availableWidth: contentWidth(of: view),
                reveal: revealed,
                image: resolveImage
            )
            displayed += applied.images
            markers += applied.markers
            displayed.sort { $0.range.location < $1.range.location }
            markers.sort { $0.range.location < $1.range.location }
            view.typingAttributes = applier.baseAttributes
            view.setNeedsLayout()
        }

        private func contentWidth(of view: UITextView) -> CGFloat {
            let width = view.bounds.width - view.textContainerInset.left - view.textContainerInset.right
                - 2 * view.textContainer.lineFragmentPadding
            return width > 50 ? width : 300
        }

        private func resolveImage(_ id: UUID) -> UIImage? {
            if let cached = imageCache[id] { return cached }
            guard let data = parent.imageData(id), let image = UIImage(data: data) else { return nil }
            imageCache[id] = image
            return image
        }

        /// Also what a Dynamic Type change runs: new fonts change every line's height, so the cached measurement is dropped.
        func contentSizeCategoryChanged() {
            applier = MarkdownStyleApplier()
            measuredWidth = 0
            textView?.setNeedsLayout()
            let units = currentUnits()
            style(NSRange(location: 0, length: units.count), units: units)
        }

        private func restyleImageParagraphs() {
            guard let first = displayed.first, let last = displayed.last else { return }
            let units = currentUnits()
            guard last.range.upperBound <= units.count else { return }
            let span = NSUnionRange(first.range, last.range)
            style(MarkdownStyler.lineAlignedRange(in: units, covering: span), units: units)
        }

        // MARK: Edit tracking

        private func beginEdit(_ range: NSRange, newLength: Int) {
            guard let view = textView else { return }
            inChange = true
            changeHandled = false

            let string = view.textStorage.mutableString
            let paragraph = string.paragraphRange(for: NSIntersectionRange(range, NSRange(location: 0, length: string.length)))
            var units = [UInt16](repeating: 0, count: paragraph.length)
            string.getCharacters(&units, range: paragraph)
            if MarkdownStyler.hasFenceMarker(units) { dirtyTouchesFence = true }
            if dirtyListSignature == nil { dirtyListSignature = MarkdownStyler.listSignature(of: units) }

            let edited = NSRange(location: range.location, length: newLength)
            if let existing = dirty {
                dirty = NSUnionRange(Self.shifted(existing, edit: range, newLength: newLength), edited)
            } else {
                dirty = edited
            }
            shiftTracked(edit: range, newLength: newLength)
        }

        private static func shifted(_ offset: Int, edit: NSRange, newLength: Int) -> Int {
            if offset >= edit.upperBound { return offset + newLength - edit.length }
            if offset > edit.location { return edit.location + newLength }
            return offset
        }

        private static func shifted(_ range: NSRange, edit: NSRange, newLength: Int) -> NSRange {
            let lower = shifted(range.location, edit: edit, newLength: newLength)
            let upper = shifted(range.upperBound, edit: edit, newLength: newLength)
            return NSRange(location: lower, length: max(upper - lower, 0))
        }

        /// Keeps the thumbnails, markers and revealed lines the edit left alone, at their new
        /// offsets; the restyle finds the rest again.
        private func shiftTracked(edit: NSRange, newLength: Int) {
            let delta = newLength - edit.length
            func shift(_ range: NSRange) -> NSRange? {
                if range.upperBound <= edit.location { return range }
                if range.location >= edit.upperBound { return NSRange(location: range.location + delta, length: range.length) }
                return nil
            }
            displayed = displayed.compactMap { item in
                var item = item
                guard let range = shift(item.range) else { return nil }
                item.range = range
                return item
            }
            markers = markers.compactMap { item in
                var item = item
                guard let range = shift(item.range) else { return nil }
                item.range = range
                return item
            }
            revealed = Self.shifted(revealed, edit: edit, newLength: newLength)
        }

        // MARK: Atomic units

        /// Image tokens and bullet and task prefixes: the caret never stops inside one.
        private var atomicRanges: [NSRange] {
            displayed.map(\.range) + markers.filter { $0.glyph != nil }.map(\.range)
        }

        /// What backspace removes whole: atomic units from anywhere inside, numbered prefixes from just after.
        fileprivate var deleteUnits: [(range: NSRange, atomic: Bool)] {
            displayed.map { ($0.range, true) } + markers.map { ($0.range, $0.glyph != nil) }
        }

        /// `range` widened over every atomic unit it partly covers, and a single-character backspace
        /// just after a list prefix widened over the prefix; nil when it touches none.
        private func expandedOverUnits(_ range: NSRange, replacement: String) -> NSRange? {
            guard range.length > 0 else { return nil }
            var result = range
            for unit in atomicRanges {
                let overlap = NSIntersectionRange(range, unit)
                if overlap.length > 0, overlap != unit { result = NSUnionRange(result, unit) }
            }
            if replacement.isEmpty, range.length == 1,
               let marker = markers.first(where: { $0.glyph == nil && $0.range.upperBound == range.upperBound }) {
                result = NSUnionRange(result, marker.range)
            }
            return result
        }

        private func replaceExpanded(_ range: NSRange, with replacement: String, in view: UITextView) {
            isExpanding = true
            beginEdit(range, newLength: replacement.utf16.count)
            changeHandled = false
            if let start = view.position(from: view.beginningOfDocument, offset: range.location),
               let end = view.position(from: start, offset: range.length),
               let textRange = view.textRange(from: start, to: end) {
                view.replace(textRange, withText: replacement)
            }
            isExpanding = false
            if !changeHandled { textViewDidChange(view) }
        }

        /// Keeps the selection from ending inside a unit: an insertion point moves to the nearer
        /// side (or past it when stepping through), and a selection grows to cover the unit.
        private func snapToAtomicBoundaries(in view: UITextView) {
            let range = view.selectedRange
            var snapped = range
            for token in atomicRanges {
                if range.length == 0 {
                    guard range.location > token.location, range.location < token.upperBound else { continue }
                    let step = abs(range.location - lastSelection.location) == 1
                    let forward = step
                        ? range.location > lastSelection.location
                        : range.location - token.location >= token.upperBound - range.location
                    snapped.location = forward ? token.upperBound : token.location
                } else {
                    var lower = snapped.location
                    var upper = snapped.upperBound
                    if lower > token.location, lower < token.upperBound { lower = token.location }
                    if upper > token.location, upper < token.upperBound { upper = token.upperBound }
                    snapped = NSRange(location: lower, length: upper - lower)
                }
            }
            guard snapped != range else { return }
            isApplying = true
            view.selectedRange = snapped
            isApplying = false
        }

        // MARK: Checkboxes

        // The checkbox tap only sees touches on a checkbox. Tracking every touch, even to fail it,
        // kept the text view's own tap from placing the caret.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = textView, gestureRecognizer === view.checkboxTap else { return true }
            return checkboxTarget(at: touch.location(in: view)) != nil
        }

        private func checkboxTarget(at point: CGPoint) -> (range: NSRange, frame: CGRect)? {
            checkboxTargets
                .filter { $0.frame.contains(point) }
                .min { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }
        }

        @objc private func checkboxTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = textView else { return }
            _ = toggleCheckbox(at: gesture.location(in: view))
        }

        /// Flips the `[ ]` or `[x]` of the task whose box is at `point`, as an undoable edit that leaves
        /// the selection and focus alone.
        @discardableResult
        func toggleCheckbox(at point: CGPoint) -> Bool {
            guard let target = checkboxTarget(at: point) else { return false }
            return toggleTask(in: target.range)
        }

        /// Flips the `[ ]` or `[x]` inside a task's prefix `range`.
        @discardableResult
        private func toggleTask(in range: NSRange) -> Bool {
            guard let view = textView else { return false }
            let units = currentUnits()
            guard range.upperBound <= units.count,
                  let open = (range.location..<range.upperBound).first(where: { units[$0] == 0x5B }),
                  open + 1 < units.count
            else { return false }
            let checked = units[open + 1] != 0x20
            replace(NSRange(location: open + 1, length: 1), in: units, with: checked ? " " : "x", notify: true, selection: view.selectedRange)
            return true
        }

        // MARK: Accessibility

        static let maxTaskActions = 20

        /// "Toggle task: <text>" actions: the task on the caret's line first, then the other tasks on screen.
        private func refreshAccessibilityActions(in view: StyledTextView, visible: ClosedRange<Int>) {
            let string = view.textStorage.mutableString
            let caretLine = string.paragraphRange(for: NSRange(location: min(view.selectedRange.location, string.length), length: 0))
            let tasks = markers.filter { $0.isTask }
            let onCaretLine = tasks.first { NSLocationInRange($0.range.location, caretLine) }
            let others = tasks.filter { $0.range.upperBound >= visible.lowerBound && $0.range.location <= visible.upperBound }
                .filter { $0.range != onCaretLine?.range }

            let entries = ([onCaretLine].compactMap { $0 } + others).prefix(Self.maxTaskActions).map { marker -> (range: NSRange, name: String) in
                let line = string.paragraphRange(for: NSRange(location: marker.range.location, length: 0))
                let textRange = NSRange(location: marker.range.upperBound, length: max(line.upperBound - marker.range.upperBound, 0))
                let text = string.substring(with: textRange).trimmingCharacters(in: .whitespacesAndNewlines)
                return (marker.range, text.isEmpty ? "Toggle task" : "Toggle task: \(String(text.prefix(60)))")
            }
            let signature = entries.map { "\($0.range.location):\($0.range.length):\($0.name)" }
            guard signature != accessibilitySignature else { return }
            accessibilitySignature = signature
            view.accessibilityCustomActions = entries.map { entry in
                UIAccessibilityCustomAction(name: entry.name) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let marker = self.markers.first(where: { $0.isTask && $0.range.location == entry.range.location })
                        else { return false }
                        return self.toggleTask(in: marker.range)
                    }
                }
            }
        }

        // MARK: Height, scrolling and overlays

        private func viewDidLayout() {
            guard let view = textView else { return }
            if abs(view.bounds.width - lastWidth) > 0.5 {
                lastWidth = view.bounds.width
                if !displayed.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.restyleImageParagraphs() }
                }
            }
            reportHeight(of: view)
            if let label = placeholderLabel {
                label.isHidden = view.textStorage.length > 0
                label.frame = CGRect(
                    x: view.textContainerInset.left,
                    y: view.textContainerInset.top,
                    width: max(view.bounds.width - view.textContainerInset.left - view.textContainerInset.right, 0),
                    height: label.font.lineHeight
                )
            }
            observeEnclosingScrollView(of: view)
            layoutOverlays(in: view)
            if needsCaretScroll {
                guard view.isFirstResponder else { needsCaretScroll = false; return }
                if view.bounds.height + 1 >= reportedHeight {
                    needsCaretScroll = false
                    scrollCaretIntoView()
                }
            }
        }

        /// Tells the owner how tall the text is, so it can size the view to it. Layout is incremental:
        /// only the paragraphs an edit invalidated are laid out again.
        private func reportHeight(of view: StyledTextView) {
            let width = view.bounds.width
            guard width > 0 else { return }
            let needed = ceil(neededHeight(of: view, width: width))
            let target = max(parent.minHeight, needed)
            guard abs(target - reportedHeight) >= 1 else { return }
            reportedHeight = target
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.height != target else { return }
                self.parent.height = target
            }
        }

        /// The height of the whole text. Measuring it lays out the whole document, so it is only redone when
        /// the width changed or the bottom of what layout has produced moved, which typing within a
        /// line doesn't do; the caret's paragraph is laid out first so a new last line shows up there.
        private func neededHeight(of view: StyledTextView, width: CGFloat) -> CGFloat {
            let insets = view.textContainerInset.top + view.textContainerInset.bottom
            guard let layout = view.textLayoutManager, let content = layout.textContentManager else {
                return view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            }
            let documentStart = content.documentRange.location
            let caret = min(view.selectedRange.upperBound, view.textStorage.length)
            if let location = content.location(documentStart, offsetBy: caret) {
                _ = layout.textLayoutFragment(for: location)
            }
            let usage = layout.usageBoundsForTextContainer.maxY
            if width == measuredWidth, abs(usage - measuredUsage) < 0.5 { return max(measuredHeight, usage + insets) }
            #if DEBUG
            fullMeasureCount += 1
            #endif
            measuredWidth = width
            measuredUsage = usage
            measuredHeight = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            return max(measuredHeight, usage + insets)
        }

        private func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView { return scroll }
                ancestor = current.superview
            }
            return nil
        }

        /// The view doesn't scroll, so overlays have to follow the form that does.
        private func observeEnclosingScrollView(of view: UIView) {
            let scroll = enclosingScrollView(of: view)
            guard scroll !== observedScrollView else { return }
            observedScrollView = scroll
            scrollObservation = scroll?.observe(\.contentOffset, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.textView,
                          !(self.displayed.isEmpty && self.markers.isEmpty && self.overlays.allSatisfy(\.isHidden) && self.markerViews.allSatisfy(\.isHidden))
                    else { return }
                    self.layoutOverlays(in: view)
                }
            }
        }

        var isHeightCacheValid: Bool { measuredWidth != 0 }

        func requestCaretScroll() {
            needsCaretScroll = true
            textView?.setNeedsLayout()
        }

        /// Scrolls the enclosing form just far enough that the caret is above the keyboard and below the navigation bar.
        func scrollCaretIntoView() {
            guard let view = textView, view.selectedRange.length == 0,
                  let scroll = enclosingScrollView(of: view), let range = view.selectedTextRange else { return }
            let caret = view.caretRect(for: range.end)
            guard !caret.isNull, !caret.isInfinite else { return }
            let rect = scroll.convert(caret, from: view)
            let inset = scroll.adjustedContentInset
            let top = scroll.contentOffset.y + inset.top
            let bottom = scroll.contentOffset.y + scroll.bounds.height - inset.bottom
            let margin: CGFloat = 12
            var offset = scroll.contentOffset.y
            if rect.maxY + margin > bottom {
                offset += rect.maxY + margin - bottom
            } else if rect.minY - margin < top {
                offset -= top - (rect.minY - margin)
            }
            let lowest = -inset.top
            let highest = max(scroll.contentSize.height - scroll.bounds.height + inset.bottom, lowest)
            offset = min(max(offset, lowest), highest)
            guard abs(offset - scroll.contentOffset.y) >= 0.5 else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
        }

        @objc private func keyboardDidShow() {
            guard textView?.isFirstResponder == true else { return }
            requestCaretScroll()
        }

        /// The text offsets of what is on screen, a little beyond it: the part of this view inside the
        /// enclosing scroll view, found by asking layout which fragments sit at its top and bottom.
        private func visibleOffsets(of view: UIView, layout: NSTextLayoutManager, content: NSTextContentManager) -> ClosedRange<Int>? {
            var visible = view.bounds
            if let scroll = enclosingScrollView(of: view) {
                visible = visible.intersection(view.convert(scroll.bounds, from: scroll))
            }
            guard !visible.isNull else { return nil }
            visible = visible.insetBy(dx: 0, dy: -300)
            let documentStart = content.documentRange.location
            let inset = (view as? UITextView)?.textContainerInset.top ?? 0

            func offset(atY y: CGFloat, end: Bool) -> Int? {
                guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(y - inset, 0))) else { return nil }
                let location = end ? fragment.rangeInElement.endLocation : fragment.rangeInElement.location
                return content.offset(from: documentStart, to: location)
            }
            let start = offset(atY: visible.minY, end: false) ?? 0
            let end = offset(atY: visible.maxY, end: true) ?? content.offset(from: documentStart, to: content.documentRange.endLocation)
            return start...max(start, end)
        }

        private func layoutOverlays(in view: StyledTextView) {
            checkboxTargets = []
            guard let layout = view.textLayoutManager,
                  let content = layout.textContentManager,
                  let visible = visibleOffsets(of: view, layout: layout, content: content)
            else {
                overlays.forEach { $0.isHidden = true }
                markerViews.forEach { $0.isHidden = true }
                return
            }
            let documentStart = content.documentRange.location
            let visibleStart = visible.lowerBound
            let visibleEnd = visible.upperBound

            func rect(of range: NSRange) -> CGRect? {
                guard let start = content.location(documentStart, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end)
                else { return nil }
                var result: CGRect?
                layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                    result = rect
                    return false
                }
                return result
            }

            var used = 0
            for item in displayed where item.range.upperBound >= visibleStart && item.range.location <= visibleEnd {
                guard let segment = rect(of: item.range) else { continue }
                let imageView = overlay(at: used, in: view, pool: &overlays, scaled: true)
                used += 1
                imageView.image = item.image
                imageView.frame = CGRect(
                    x: segment.minX + view.textContainerInset.left,
                    y: segment.minY + view.textContainerInset.top,
                    width: item.size.width,
                    height: item.size.height
                )
                imageView.isHidden = false
            }
            for extra in overlays.dropFirst(used) { extra.isHidden = true }

            var usedMarkers = 0
            for item in markers where item.glyph != nil && item.range.upperBound >= visibleStart && item.range.location <= visibleEnd {
                guard let glyph = item.glyph, let segment = rect(of: item.range) else { continue }
                let imageView = overlay(at: usedMarkers, in: view, pool: &markerViews, scaled: false)
                usedMarkers += 1
                imageView.image = glyph
                imageView.tintColor = item.tint
                let gap = applier.bodySize * 0.3
                let x = segment.minX + view.textContainerInset.left + max(item.width - glyph.size.width - gap, 0)
                let y = segment.minY + view.textContainerInset.top + (segment.height - glyph.size.height) / 2
                imageView.frame = CGRect(x: x, y: y, width: glyph.size.width, height: glyph.size.height)
                imageView.isHidden = false
                if item.isTask {
                    let hit = CGRect(
                        x: imageView.frame.minX - 10,
                        y: segment.minY + view.textContainerInset.top,
                        width: imageView.frame.width + 20,
                        height: segment.height
                    )
                    checkboxTargets.append((item.range, hit))
                }
            }
            for extra in markerViews.dropFirst(usedMarkers) { extra.isHidden = true }
            refreshAccessibilityActions(in: view, visible: visible)
        }

        private func overlay(at index: Int, in view: UIView, pool: inout [UIImageView], scaled: Bool) -> UIImageView {
            if index < pool.count { return pool[index] }
            let imageView = UIImageView()
            imageView.contentMode = scaled ? .scaleAspectFit : .center
            if scaled {
                imageView.layer.cornerRadius = 6
                imageView.clipsToBounds = true
            }
            imageView.isUserInteractionEnabled = false
            imageView.isAccessibilityElement = false
            view.insertSubview(imageView, at: 0)
            pool.append(imageView)
            return imageView
        }
    }
}
