import Foundation
import SwiftData

/// Kinds of extra content that can be attached under a thought.
/// Adding a kind = a new case here plus one view in Features/Blocks.
enum BlockKind: String, CaseIterable, Identifiable {
    case blurred

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blurred: "Blurred text"
        }
    }

    var systemImage: String {
        switch self {
        case .blurred: "eye.slash"
        }
    }
}

/// Extra content attached to a thought, rendered under its body.
@Model
final class Block {
    var id: UUID = UUID()
    var kindRaw: String = BlockKind.blurred.rawValue
    var content: String = ""
    var title: String? = nil
    var order: Int = 0
    var thought: Thought? = nil

    init(id: UUID = UUID(), kind: BlockKind, content: String, title: String? = nil, order: Int) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.title = title
        self.order = order
    }

    var kind: BlockKind {
        BlockKind(rawValue: kindRaw) ?? .blurred
    }
}
