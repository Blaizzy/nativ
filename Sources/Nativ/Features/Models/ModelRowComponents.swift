import SwiftUI

struct ModelRowActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(title)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isDisabled {
            return Color.secondary.opacity(0.45)
        }
        return isHovering ? tint : .secondary
    }

    private var backgroundColor: Color {
        guard isHovering, !isDisabled else {
            return Color.secondary.opacity(0.10)
        }
        return tint.opacity(0.13)
    }
}

private struct ModelRowBackground: ViewModifier {
    let isHighlighted: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.38)
        }
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.90)
        }
        if isHovered {
            return Color.accentColor.opacity(0.40)
        }
        return Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        isHighlighted ? 1.5 : (isHovered ? 1 : 0.5)
    }
}

extension View {
    func modelRowBackground(
        isHighlighted: Bool,
        isHovered: Bool = false
    ) -> some View {
        modifier(
            ModelRowBackground(
                isHighlighted: isHighlighted,
                isHovered: isHovered
            )
        )
    }
}
