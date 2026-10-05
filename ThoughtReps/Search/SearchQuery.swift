import Foundation

/// Turns what the user typed into an FTS5 `MATCH` expression.
enum SearchQuery {
    /// More terms than this are ignored, which keeps a pasted paragraph from becoming a huge query.
    static let maxTerms = 8
    static let maxTermLength = 64

    /// The words of `input`: runs of letters, digits and combining marks, split at everything else
    /// (the same boundaries the index's tokenizer uses). Every term is quoted, so FTS operator words are plain words.
    static func terms(_ input: String) -> [String] {
        var terms: [String] = []
        var current = String.UnicodeScalarView()
        func finish() {
            let word = String(current)
            current = String.UnicodeScalarView()
            guard !word.isEmpty else { return }
            terms.append(String(word.prefix(maxTermLength)))
        }
        for scalar in input.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else {
                finish()
            }
        }
        finish()
        return Array(terms.prefix(maxTerms))
    }

    /// `"one"* "two"*`: every term is a quoted prefix match and all must match. Nil when the
    /// input has no searchable word, in which case there is nothing to search for.
    static func matchExpression(for input: String) -> String? {
        let terms = terms(input)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark, .privateUse:
            true
        default:
            false
        }
    }
}
