import SwiftUI

/// Nativ's semantic color contract.
///
/// Every concrete value is stored in `Assets.xcassets` with Light and Dark
/// appearances that match the Figma `Appearance` collection. Aliases stay as
/// aliases here so the same relationships exist in design and production.
enum NativColor {
    enum Surface {
        static let window = Color(.nativSurfaceWindow)
        static let primary = Color(.nativSurfacePrimary)
        static let secondary = Color(.nativSurfaceSecondary)
        static let tertiary = Color(.nativSurfaceTertiary)
        static let strong = Color(.nativSurfaceStrong)
        static let underPage = Color(.nativSurfaceUnderPage)
        static let selected = Color(.nativSurfaceSelected)
        static let selectedQuiet = Color(.nativSurfaceSelectedQuiet)

        /// Preview fallback only. Production sidebars should use system material.
        static let sidebarMaterialFallback = Color(.nativSurfaceSidebarMaterial)
    }

    enum Content {
        static let strong = Color(.nativContentStrong)
        static let primary = Color(.nativContentPrimary)
        static let secondary = Color(.nativContentSecondary)
        static let tertiary = Color(.nativContentTertiary)
        static let quaternary = Color(.nativContentQuaternary)
        static let placeholder = Color(.nativContentPlaceholder)
        static let onAccentPrimary = Color(.nativContentOnAccentPrimary)
        static let onAccentSecondary = Color(.nativContentOnAccentSecondary)

        /// Figma alias: `content/danger-primary` → `status/danger`.
        static var dangerPrimary: Color { Status.danger }
    }

    enum Border {
        static let primary = Color(.nativBorderPrimary)
        static let secondary = Color(.nativBorderSecondary)
    }

    enum Fill {
        static let primary = Color(.nativFillPrimary)
        static let secondary = Color(.nativFillSecondary)
        static let tertiary = Color(.nativFillTertiary)
        static let quaternary = Color(.nativFillQuaternary)
        static let quinary = Color(.nativFillQuinary)
    }

    enum Accent {
        static let base = Color(.accent)
        static let hover = Color(.nativAccentHover)
        static let subtle = Color(.nativAccentSubtle)
        static let selected = Color(.nativAccentSelected)
        static let emphasis = Color(.nativAccentEmphasis)
        static let focusRing = Color(.nativAccentFocusRing)
    }

    enum Status {
        static let success = Color(.nativStatusSuccess)
        static let warning = Color(.nativStatusWarning)
        static let danger = Color(.nativStatusDanger)

        /// Figma alias: `status/active` → `accent/base`.
        static var active: Color { Accent.base }

        /// Figma alias: `status/neutral` → `content/secondary`.
        static var neutral: Color { Content.secondary }
    }

    enum Chart {
        static let series1 = Color(.nativChartSeries1)
        static let series2 = Color(.nativChartSeries2)
        static let series3 = Color(.nativChartSeries3)
        static let series4 = Color(.nativChartSeries4)
        static let series5 = Color(.nativChartSeries5)
        static let series6 = Color(.nativChartSeries6)

        /// Figma alias: `chart/panel` → `surface/primary`.
        static var panel: Color { Surface.primary }

        /// Figma alias: `chart/axis-text` → `content/secondary`.
        static var axisText: Color { Content.secondary }

        /// Figma alias: `chart/axis-label` → `content/tertiary`.
        static var axisLabel: Color { Content.tertiary }

        static let panelStroke = Color(.nativChartPanelStroke)
        static let grid = Color(.nativChartGrid)
    }
}
