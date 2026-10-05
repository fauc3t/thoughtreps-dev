import SwiftUI
import MarkdownUI

extension Theme {
    /// Thought Reps' Markdown look: font sizes are `em` multiples of the Dynamic-Type-scaled
    /// body size, with semantic colors for light and dark mode.
    @MainActor static let thoughtReps: Theme = {
        let gap = RelativeSize.rem(0.7)
        return Theme()
            .text {
                FontSize(.em(1))
            }
            .code {
                FontFamilyVariant(.monospaced)
                BackgroundColor(Color.secondary.opacity(0.15))
            }
            .strong {
                FontWeight(.semibold)
            }
            // MarkdownUI can't style tag links apart from other links, so every link is accent
            // colored without an underline.
            .link {
                ForegroundColor(.accentColor)
                UnderlineStyle(nil)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.65))
                        FontWeight(.bold)
                    }
                    .markdownMargin(top: .rem(0.25), bottom: gap)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.3))
                        FontWeight(.bold)
                    }
                    .markdownMargin(top: .rem(0.25), bottom: gap)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(1.18))
                        FontWeight(.semibold)
                    }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .blockquote { configuration in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .zero, bottom: gap)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.94))
                            BackgroundColor(nil)
                        }
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                .markdownMargin(top: .zero, bottom: gap)
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: .rem(0.35))
            }
            .bulletedListMarker { configuration in
                Text(["•", "◦", "▪"][min(configuration.listLevel, 3) - 1])
                    .foregroundStyle(.secondary)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .numberedListMarker { configuration in
                Text("\(configuration.itemNumber).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isCompleted ? Color.accentColor : Color.secondary)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: Color(.separator)))
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: .zero, bottom: gap)
            }
    }()
}
