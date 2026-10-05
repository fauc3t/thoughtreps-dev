import Foundation

enum SharedContent {
    /// Text first, then the URL on its own line, unless the text already contains the URL.
    static func merge(text: String?, url: URL?) -> String {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url else { return text }
        let link = url.absoluteString
        if text.isEmpty { return link }
        if text.contains(link) { return text }
        return text + "\n" + link
    }
}
