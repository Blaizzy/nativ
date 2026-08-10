import AppKit
import SwiftUI

enum ChatWorkspaceMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case images = "Images"

    var id: Self { self }
}

struct ChatWorkspacePicker: View {
    let selection: ChatWorkspaceMode
    let onSelect: (ChatWorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatWorkspaceMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(
                            .system(
                                size: 12,
                                weight: mode == selection ? .semibold : .medium
                            )
                        )
                        .foregroundStyle(mode == selection ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if mode == selection {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.09))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue) workspace")
                .accessibilityAddTraits(mode == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.1), value: selection)
    }
}
