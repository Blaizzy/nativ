import SwiftUI

struct ToolExposureModeControl: View {
    @Binding var mode: ToolExposureMode
    var title: String

    var body: some View {
        Picker("Agent access", selection: $mode) {
            ForEach(ToolExposureMode.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 168)
        .help(helpText)
        .accessibilityLabel("Agent access for \(title)")
        .accessibilityValue(mode.title)
        .accessibilityHint(helpText)
    }

    private var helpText: String {
        switch mode {
        case .off:
            "Off prevents the agent from using this capability."
        case .automatic:
            "Auto keeps it out of regular prompts and lets the agent find it when needed."
        case .on:
            "On includes it in every tool-capable model prompt."
        }
    }
}

struct ToolExposureModeExplanation: View {
    var body: some View {
        HStack(spacing: 14) {
            explanation("Off", "Unavailable")
            explanation("Auto", "Discoverable")
            explanation("On", "Always shared")
        }
        .nativTextStyle(.metadata)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Off is unavailable. Auto is discoverable when needed. On is shared with every model prompt."
        )
    }

    private func explanation(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(detail)
        }
    }
}
