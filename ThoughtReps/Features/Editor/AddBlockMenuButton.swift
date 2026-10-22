import SwiftUI

/// The "Add block" menu button of the editor's list, with the same choices as `AddBlockMenuItems` (both built from `BlockKind.allCases`).
/// It's a UIKit button because SwiftUI's `Menu` has no open callback: the menu's items come from an
/// uncached deferred element, which UIKit asks for as the menu opens, and that is where the keyboard goes down.
struct AddBlockMenuButton: UIViewRepresentable {
    let onWillOpen: () -> Void
    let onAdd: (BlockKind) -> Void

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Add block"
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .secondaryLabel
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak button] in
                var attributes = $0
                attributes.font = .preferredFont(forTextStyle: .footnote, compatibleWith: button?.traitCollection)
                return attributes
            }
        }
        button.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: UIButton, _) in
            button.setNeedsUpdateConfiguration()
            button.invalidateIntrinsicContentSize()
        }
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "addBlockInList"
        button.contentHorizontalAlignment = .leading
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let actions = BlockKind.allCases.map { kind in
            UIAction(title: kind.label, image: UIImage(systemName: kind.systemImage)) { _ in onAdd(kind) }
        }
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            onWillOpen()
            completion(actions)
        }])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}
