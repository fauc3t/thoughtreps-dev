import SwiftUI
import MarkdownUI

extension Theme {
    /// Thought Reps' Markdown look: font sizes are `em` multiples of the Dynamic-Type-scaled
    /// body size, with semantic colors for light and dark mode. `font` picks the body typeface;
    /// headings stay Archivo at the same size either way.
    @MainActor static func thoughtReps(font: ThoughtFont) -> Theme {
        let gap = RelativeSize.rem(0.7)
        let mono = font == .paperMono
        // Heading `em`s are relative to the body, which Paper Mono shrinks; this undoes that.
        let heading: CGFloat = mono ? 1 / ThoughtFont.monoScale : 1
        let title = ThemeManager.shared.current.title
        return Theme()
            .text {
                if mono {
                    FontFamily(.custom(InkFontName.monoRegular))
                    FontSize(.em(ThoughtFont.monoScale))
                }
                if !mono {
                    FontSize(.em(1))
                }
                if ThemeManager.shared.current != .ink {
                    ForegroundColor(Color.ink)
                }
            }
            .code {
                FontFamilyVariant(.monospaced)
                BackgroundColor(Color.codeSpan)
            }
            .strong {
                if mono {
                    FontFamily(.custom(InkFontName.monoSemiBold))
                }
                if !mono {
                    FontWeight(.semibold)
                }
            }
            .emphasis {
                if mono {
                    FontFamily(.custom(InkFontName.monoItalic))
                }
                if !mono {
                    FontStyle(.italic)
                }
            }
            // MarkdownUI can't style tag links apart from other links, so every link is accent
            // colored without an underline.
            .link {
                ForegroundColor(Color.accent)
                UnderlineStyle(nil)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.bold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.bold)
                        }
                        FontSize(.em(1.65 * heading))
                    }
                    .markdownMargin(top: .rem(0.25), bottom: gap)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.bold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.bold)
                        }
                        FontSize(.em(1.3 * heading))
                    }
                    .markdownMargin(top: .rem(0.25), bottom: gap)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.semibold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.semibold)
                        }
                        FontSize(.em(1.18 * heading))
                    }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.semibold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.semibold)
                        }
                        FontSize(.em(heading))
                    }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.semibold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.semibold)
                        }
                        FontSize(.em(heading))
                    }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if let name = title.customName(.semibold) {
                            FontFamily(.custom(name))
                        }
                        if let design = title.systemDesign {
                            FontFamily(.system(design))
                            FontWeight(.semibold)
                        }
                        FontSize(.em(heading))
                    }
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: .zero, bottom: gap)
            }
            .blockquote { configuration in
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(Color.ink)
                        .frame(width: 2)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(Color.subtle) }
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
                            FontSize(.em(0.94 * heading))
                            BackgroundColor(nil)
                        }
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface))
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
                    .foregroundStyle(Color.subtle)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .numberedListMarker { configuration in
                Text("\(configuration.itemNumber).")
                    .monospacedDigit()
                    .foregroundStyle(Color.subtle)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isCompleted ? Color.accent : Color.subtle)
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
    }
}
