import SwiftUI

extension Color {
    /// Resolves a catalog/kit tint name to a color, defaulting to the accent.
    static func nativTint(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "orange": return .orange
        case "teal": return .teal
        case "purple": return .purple
        case "green": return .green
        case "red": return .red
        case "pink": return .pink
        case "yellow": return .yellow
        case "indigo": return .indigo
        case "mint": return .mint
        case "primary": return .primary
        default: return .accentColor
        }
    }
}

// Shared, flat UI primitives used across Nativ. These favor whitespace and a
// single tint over nested filled tiles, so a surface reads as one calm plane
// rather than a stack of boxes. Prefer these over re-rolling a pill/badge/dot.

/// A semantic status color, shared by dots, badges, and tool states.
enum NativStatusTone {
    case neutral
    case active
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

/// A small filled dot for connection/health status, optionally pulsing while live.
struct NativStatusDot: View {
    let tone: NativStatusTone
    var pulsing: Bool = false
    var diameter: CGFloat = 7

    @State private var animating = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: diameter, height: diameter)
            .opacity(pulsing && animating ? 0.35 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: animating
            )
            .onAppear { animating = pulsing }
    }
}

/// A compact capsule badge: a short label tinted by tone, with an optional leading symbol.
struct NativStatusBadge: View {
    let text: String
    var tone: NativStatusTone = .neutral
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.12), in: Capsule())
    }
}

/// A monospaced code/JSON block with a subtle background and selectable text.
/// JSON content is pretty-printed; anything else is shown verbatim.
struct NativCodeBlock: View {
    let raw: String
    var lineLimit: Int? = nil

    private var display: String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: formatted, encoding: .utf8)
        else { return raw }
        return string
    }

    var body: some View {
        Text(display)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

/// A soft, tinted rounded tile holding an SF Symbol — or a bundled logo image
/// when `logoAssetName` resolves. Used for catalog logos and section glyphs.
struct NativTintedIconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var logoAssetName: String? = nil
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let logoAssetName, let nsImage = NSImage(named: logoAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        )
    }
}

/// A borderless close (X) button that reveals a soft circular hover hue —
/// the standard dismiss affordance for Nativ's popovers and sheets.
struct NativHoverCloseButton: View {
    let action: () -> Void
    var help: String = "Close"

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
