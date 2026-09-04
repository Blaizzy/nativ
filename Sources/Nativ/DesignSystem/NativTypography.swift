import SwiftUI

/// The Figma typography ramp expressed once, independently of view-specific meaning.
/// Application views should consume `NativTypography.Style` rather than these tokens.
private enum NativTypeScale {
    struct Token {
        let font: Font
        let lineHeight: CGFloat
        let lineSpacing: CGFloat
    }

    // The Figma letter-spacing values mirror SF Pro's optical metrics. SwiftUI's
    // system font supplies those metrics; applying `.tracking` again would add a
    // second adjustment. Line spacing is only added where SwiftUI's native
    // baseline distance is smaller than the Figma style's line height.
    static let titleExtraLargeMedium = system(size: 38, lineHeight: 44, nativeLineHeight: 45, weight: .medium)
    static let titleLargeMedium = system(size: 26, lineHeight: 32, nativeLineHeight: 30, weight: .medium)
    static let titleLargeBold = system(size: 26, lineHeight: 32, nativeLineHeight: 30, weight: .bold)
    static let titleMediumMedium = system(size: 22, lineHeight: 26, nativeLineHeight: 26, weight: .medium)
    static let titleMediumBold = system(size: 22, lineHeight: 26, nativeLineHeight: 26, weight: .bold)
    static let titleSmallMedium = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .medium)
    static let titleSmallBold = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .bold)

    static let textLargeRegular = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .regular)
    static let textLargeMedium = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .medium)
    static let textLargeSemibold = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .semibold)
    static let textLargeBold = system(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .bold)

    static let textMediumRegular = system(size: 15, lineHeight: 20, nativeLineHeight: 19, weight: .regular)
    static let textMediumMedium = system(size: 15, lineHeight: 20, nativeLineHeight: 19, weight: .medium)
    static let textMediumSemibold = system(size: 15, lineHeight: 20, nativeLineHeight: 19, weight: .semibold)
    static let textMediumBold = system(size: 15, lineHeight: 20, nativeLineHeight: 19, weight: .bold)

    static let textSmallRegular = system(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .regular)
    static let textSmallMedium = system(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .medium)
    static let textSmallSemibold = system(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .semibold)
    static let textSmallBold = system(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .bold)

    static let textExtraSmallRegular = system(size: 11, lineHeight: 14, nativeLineHeight: 14, weight: .regular)
    static let textExtraSmallMedium = system(size: 11, lineHeight: 14, nativeLineHeight: 14, weight: .medium)
    static let textExtraSmallSemibold = system(size: 11, lineHeight: 14, nativeLineHeight: 14, weight: .semibold)
    static let textExtraSmallBold = system(size: 11, lineHeight: 14, nativeLineHeight: 14, weight: .bold)

    static let metadataNumeric = Token(
        font: textExtraSmallRegular.font.monospacedDigit(),
        lineHeight: textExtraSmallRegular.lineHeight,
        lineSpacing: textExtraSmallRegular.lineSpacing
    )

    static let technicalDisplay = monospaced(size: 17, lineHeight: 22, nativeLineHeight: 20, weight: .semibold)
    static let technicalTitle = monospaced(size: 15, lineHeight: 20, nativeLineHeight: 19, weight: .semibold)
    static let technicalLabel = monospaced(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .medium)
    static let code = monospaced(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .regular)
    static let codeEmphasized = monospaced(size: 13, lineHeight: 16, nativeLineHeight: 16, weight: .semibold)

    private static func system(
        size: CGFloat,
        lineHeight: CGFloat,
        nativeLineHeight: CGFloat,
        weight: Font.Weight
    ) -> Token {
        Token(
            font: .system(size: size, weight: weight),
            lineHeight: lineHeight,
            lineSpacing: max(0, lineHeight - nativeLineHeight)
        )
    }

    private static func monospaced(
        size: CGFloat,
        lineHeight: CGFloat,
        nativeLineHeight: CGFloat,
        weight: Font.Weight
    ) -> Token {
        Token(
            font: .system(size: size, weight: weight, design: .monospaced),
            lineHeight: lineHeight,
            lineSpacing: max(0, lineHeight - nativeLineHeight)
        )
    }
}

/// Stable, semantic typography roles used by Nativ views.
/// Figma scale changes are mapped here without renaming application call sites.
enum NativTypography {
    enum Style {
        case displayTitle
        case heroSubtitle
        case pageTitle
        case brandTitle
        case sheetTitle
        case detailTitle
        case cardTitle
        case compactCardTitle
        case emptyStateTitle
        case sidebarSectionTitle
        case sidebarItem
        case subsectionTitle
        case sectionTitle
        case rowTitleEmphasized
        case rowTitle
        case body
        case supporting
        case supportingEmphasized
        case metadata
        case metadataNumeric
        case badge
        case badgeMuted
        case badgeStrong
        case actionLabel
        case prominentActionLabel
        case statusBadge
        case chartLabel
        case technicalDisplayTitle
        case technicalTitle
        case technicalLabel
        case code
        case codeEmphasized

        fileprivate var token: NativTypeScale.Token {
            switch self {
            case .displayTitle:
                NativTypeScale.titleExtraLargeMedium
            case .heroSubtitle:
                NativTypeScale.textLargeRegular
            case .pageTitle:
                NativTypeScale.titleLargeMedium
            case .brandTitle:
                NativTypeScale.titleMediumMedium
            case .sheetTitle:
                NativTypeScale.titleSmallBold
            case .detailTitle:
                NativTypeScale.titleSmallMedium
            case .cardTitle:
                NativTypeScale.textMediumSemibold
            case .compactCardTitle:
                NativTypeScale.textSmallSemibold
            case .emptyStateTitle:
                NativTypeScale.textMediumMedium
            case .sidebarSectionTitle:
                NativTypeScale.textMediumSemibold
            case .sidebarItem:
                NativTypeScale.textMediumRegular
            case .subsectionTitle, .sectionTitle, .rowTitleEmphasized:
                NativTypeScale.textSmallSemibold
            case .rowTitle:
                NativTypeScale.textSmallMedium
            case .body:
                NativTypeScale.textMediumRegular
            case .supporting:
                NativTypeScale.textSmallRegular
            case .supportingEmphasized:
                NativTypeScale.textSmallMedium
            case .metadata:
                NativTypeScale.textExtraSmallRegular
            case .metadataNumeric:
                NativTypeScale.metadataNumeric
            case .badge, .statusBadge:
                NativTypeScale.textExtraSmallSemibold
            case .badgeMuted, .actionLabel:
                NativTypeScale.textExtraSmallMedium
            case .prominentActionLabel:
                NativTypeScale.textLargeMedium
            case .badgeStrong:
                NativTypeScale.textExtraSmallBold
            case .chartLabel:
                NativTypeScale.textExtraSmallRegular
            case .technicalDisplayTitle:
                NativTypeScale.technicalDisplay
            case .technicalTitle:
                NativTypeScale.technicalTitle
            case .technicalLabel:
                NativTypeScale.technicalLabel
            case .code:
                NativTypeScale.code
            case .codeEmphasized:
                NativTypeScale.codeEmphasized
            }
        }
    }
}

private struct NativTypographyModifier: ViewModifier {
    let style: NativTypography.Style

    func body(content: Content) -> some View {
        let token = style.token
        content
            .font(token.font)
            .lineSpacing(token.lineSpacing)
    }
}

extension View {
    /// Applies one of Nativ's application-wide semantic typography roles.
    func nativTextStyle(_ style: NativTypography.Style) -> some View {
        modifier(NativTypographyModifier(style: style))
    }
}

private struct NativTypographyPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                previewSection("Titles") {
                    previewRow("Display title", sample: "Welcome to Nativ", style: .displayTitle)
                    previewRow("Hero subtitle", sample: "Let’s get you set up", style: .heroSubtitle)
                    previewRow("Page title", sample: "Extensions", style: .pageTitle)
                    previewRow("Brand title", sample: "Nativ", style: .brandTitle)
                    previewRow("Sheet title", sample: "Edit Tool", style: .sheetTitle)
                    previewRow("Detail title", sample: "Featured Kit", style: .detailTitle)
                    previewRow("Card title", sample: "Scheduled Task", style: .cardTitle)
                    previewRow("Compact card title", sample: "Artifact.jpg", style: .compactCardTitle)
                    previewRow("Empty-state title", sample: "Drop files here", style: .emptyStateTitle)
                }

                previewSection("Navigation and content") {
                    previewRow("Sidebar section", sample: "Chats", style: .sidebarSectionTitle)
                    previewRow("Sidebar item", sample: "Recent conversation", style: .sidebarItem)
                    previewRow("Subsection title", sample: "Custom Servers", style: .subsectionTitle)
                    previewRow("Section title", sample: "Capabilities", style: .sectionTitle)
                    previewRow("Emphasized row", sample: "Image Generation", style: .rowTitleEmphasized)
                    previewRow("Row title", sample: "Web Search", style: .rowTitle)
                    previewRow("Body", sample: "Primary interface content", style: .body)
                    previewRow("Supporting", sample: "Additional context and guidance", style: .supporting)
                    previewRow("Supporting emphasized", sample: "Field or control label", style: .supportingEmphasized)
                }

                previewSection("Metadata and labels") {
                    previewRow("Metadata", sample: "Updated today", style: .metadata)
                    previewRow("Numeric metadata", sample: "12 of 48", style: .metadataNumeric)
                    previewRow("Badge", sample: "BUILT-IN", style: .badge)
                    previewRow("Muted badge", sample: "Optional", style: .badgeMuted)
                    previewRow("Strong badge", sample: "PDF", style: .badgeStrong)
                    previewRow("Action label", sample: "Enable", style: .actionLabel)
                    previewRow("Prominent action", sample: "Continue", style: .prominentActionLabel)
                    previewRow("Status badge", sample: "Connected", style: .statusBadge)
                    previewRow("Chart label", sample: "12 AM", style: .chartLabel)
                }

                previewSection("Technical") {
                    previewRow("Technical display", sample: "web_search", style: .technicalDisplayTitle)
                    previewRow("Technical title", sample: "read_file", style: .technicalTitle)
                    previewRow("Technical label", sample: "POST", style: .technicalLabel)
                    previewRow("Code", sample: #"{"query":"Nativ"}"#, style: .code)
                    previewRow("Code emphasized", sample: "GET /v1/models", style: .codeEmphasized)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativColor.Surface.window)
    }

    private func previewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .nativTextStyle(.sectionTitle)
            content()
        }
    }

    private func previewRow(
        _ name: String,
        sample: String,
        style: NativTypography.Style
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(name)
                .nativTextStyle(.metadata)
                .foregroundStyle(NativColor.Content.secondary)
                .frame(width: 150, alignment: .leading)
            Text(sample)
                .nativTextStyle(style)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Typography") {
    NativTypographyPreview()
        .frame(width: 520, height: 760)
}
