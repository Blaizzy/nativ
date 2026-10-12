import SwiftUI

struct ToolExposureModeControl: View {
    @Binding var mode: ToolExposureMode
    var title: String
    var turnOffWarning: String?
    var options: [ToolExposureMode]
    @State private var showsTurnOffConfirmation = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    Text(option.title)
                }
            }
        } label: {
            Text(mode.title)
            .font(.system(size: 11, weight: mode == .on ? .semibold : .medium))
            .foregroundStyle(mode.tint)
            .padding(.horizontal, 8)
            .frame(minWidth: 104, minHeight: 24)
            .background(
                mode.background,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(mode.borderOpacity), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(mode.hoverExplanation)
        .accessibilityLabel("Agent access for \(title)")
        .accessibilityValue(mode.availabilityText)
        .accessibilityHint("Choose \(options.map(\.title).formatted(.list(type: .or))).")
        .alert("Turn Off \(title)?", isPresented: $showsTurnOffConfirmation) {
            Button("Turn Off", role: .destructive) {
                mode = .off
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(turnOffWarning ?? "")
        }
    }

    init(
        mode: Binding<ToolExposureMode>,
        title: String,
        turnOffWarning: String? = nil,
        options: [ToolExposureMode] = ToolExposureMode.allCases
    ) {
        _mode = mode
        self.title = title
        self.turnOffWarning = turnOffWarning
        self.options = options
    }

    private func select(_ newMode: ToolExposureMode) {
        if newMode == .off, mode != .off, turnOffWarning != nil {
            showsTurnOffConfirmation = true
        } else {
            mode = newMode
        }
    }
}

struct ToolExposureModeExplanation: View {
    var body: some View {
        Text("Off hides a tool, Discoverable lets Tool Search find it, and On includes it with every request.")
        .legacyTextStyle(.metadata)
        .foregroundStyle(.secondary)
    }
}

extension ToolExposureMode {
    var availabilityText: String {
        switch self {
        case .off: "Unavailable to chat"
        case .automatic: "Discoverable"
        case .on: "Available to chat"
        }
    }

    var hoverExplanation: String {
        switch self {
        case .off: "Unexposed anywhere."
        case .automatic: "Discoverable when the model calls tool_search."
        case .on: "Exposed to the model every time."
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
        case .off: .secondary.opacity(0.65)
        case .automatic: .secondary
        case .on: .primary
        }
    }

    var background: Color {
        Color.primary.opacity(self == .on ? 0.08 : self == .automatic ? 0.045 : 0.02)
    }

    var borderOpacity: Double {
        switch self {
        case .off: 0.06
        case .automatic: 0.1
        case .on: 0.16
        }
    }
}
