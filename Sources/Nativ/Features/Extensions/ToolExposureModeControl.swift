import SwiftUI

struct ToolExposureModeControl: View {
    @Binding var mode: ToolExposureMode
    var title: String
    var turnOffWarning: String?
    @State private var showsTurnOffConfirmation = false

    var body: some View {
        Button {
            select(mode.next)
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
                    select(option)
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
        turnOffWarning: String? = nil
    ) {
        _mode = mode
        self.title = title
        self.turnOffWarning = turnOffWarning
    }

    private func select(_ newMode: ToolExposureMode) {
        if newMode == .off, mode != .off, turnOffWarning != nil {
            showsTurnOffConfirmation = true
        } else {
            mode = newMode
        }
    }
}

enum ToolExposureModeCopy {
    static let toolSearchTurnOffWarning =
        "Auto tools will be unavailable to chat until Tool Search is set to Auto or On."
}

struct ToolExposureModeExplanation: View {
    var body: some View {
        Text("Click the access button to cycle between Off, Auto, and On.")
        .nativTextStyle(.metadata)
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
