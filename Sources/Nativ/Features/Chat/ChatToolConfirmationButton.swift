import AppKit
import SwiftUI

struct ChatToolConfirmationButton: View {
    @AppStorage("chat.hasUsedToolConfirmationReturn") private var hasUsedReturn = false

    var title = "Confirm"
    var systemImage: String?
    var showsReturnHint = true
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: confirm) {
                if let systemImage {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: systemImage)
                    }
                } else {
                    Text(title)
                }
            }
            .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("\(title) (Return)")
                .accessibilityLabel(accessibilityLabel ?? title)
                .accessibilityHint("Press Return to \(title.lowercased()).")

            if showsReturnHint {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(hasUsedReturn ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private func confirm() {
        if let event = NSApp.currentEvent, event.type == .keyDown {
            guard !event.isARepeat else { return }
            if event.keyCode == 36 || event.keyCode == 76 {
                hasUsedReturn = true
            }
        }
        action()
    }
}
