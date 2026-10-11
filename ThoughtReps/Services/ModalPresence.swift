import UIKit

/// Keyboard commands act on the screen underneath, so they stand down while a sheet, alert or cover is up:
/// a second sheet requested from the root would otherwise appear after the first one closes.
@MainActor
enum ModalPresence {
    static var isPresenting: Bool { isPresenting(from: rootViewController) }

    /// The editor is always the first sheet over the root, so anything presented on top of it
    /// (the discard dialog, a picker, an alert) means its shortcuts should stand down.
    static var isPresentingOverFirstSheet: Bool { isPresentingOverFirstSheet(from: rootViewController) }

    static func isPresenting(from root: UIViewController?) -> Bool {
        root?.presentedViewController != nil
    }

    static func isPresentingOverFirstSheet(from root: UIViewController?) -> Bool {
        root?.presentedViewController?.presentedViewController != nil
    }

    private static var rootViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.rootViewController
    }
}
