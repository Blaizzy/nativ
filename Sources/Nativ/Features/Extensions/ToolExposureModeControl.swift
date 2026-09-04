import SwiftUI

struct ToolExposureModeControl: View {
    @Binding var mode: ToolExposureMode
    var title: String

    var body: some View {
        Button {
            mode = mode.next
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(mode.tint)
                .frame(width: 30, height: 24)
                .background(
                    mode.tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(ToolExposureMode.allCases, id: \.self) { option in
                Button {
                    mode = option
                } label: {
                    Label {
                        Text("\(option.title) — \(option.availabilityText)")
                    } icon: {
                        Image(systemName: option == mode ? "checkmark" : option.systemImage)
                    }
                }
            }
        }
        .help(mode.availabilityText)
        .accessibilityLabel("Agent access for \(title)")
        .accessibilityValue(mode.availabilityText)
        .accessibilityHint(
            "Click to switch to \(mode.next.title), \(mode.next.availabilityText.lowercased())."
        )
    }
}

struct ToolExposureModeExplanation: View {
    var body: some View {
        Text("Click the access button to cycle between Off, Auto, and On.")
        .nativTextStyle(.metadata)
        .foregroundStyle(.secondary)
    }
}

private extension ToolExposureMode {
    var availabilityText: String {
        switch self {
        case .off: "Unavailable to chat"
        case .automatic: "Discoverable"
        case .on: "Available to chat"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "minus"
        case .automatic: "magnifyingglass"
        case .on: "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .off: .secondary
        case .automatic: .blue
        case .on: .green
        }
    }
}
