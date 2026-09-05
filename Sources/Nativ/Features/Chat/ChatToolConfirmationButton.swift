import AppKit
import SwiftUI

struct ChatToolConfirmationButton: View {
    @AppStorage("chat.hasUsedToolConfirmationReturn") private var hasUsedReturn = false

    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Confirm", action: confirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Confirm (Return)")
                .accessibilityHint("Press Return to confirm.")

            Image(systemName: "return")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(hasUsedReturn ? 0 : 1)
                .accessibilityHidden(true)
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
