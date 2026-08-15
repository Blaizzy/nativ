import SwiftUI

struct ChatAttachmentNoticesView: View {
    let notices: [ChatAttachmentNotice]
    let onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notices) { notice in
                HStack(alignment: .top, spacing: 9) {
                    statusIcon(for: notice)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        if let title = notice.title {
                            Text(title)
                                .bold()
                                .foregroundStyle(.primary)
                        }

                        Text(notice.message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if notice.isDismissible {
                        Button("Dismiss", systemImage: "xmark") {
                            onDismiss(notice.id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Dismiss warning")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(noticeBackground(for: notice), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(noticeBorder(for: notice), lineWidth: 0.75)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusIcon(for notice: ChatAttachmentNotice) -> some View {
        switch notice.severity {
        case .progress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing attachment")
        case .warning, .error:
            Image(systemName: notice.systemImage ?? "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
        }
    }

    private func noticeBackground(for notice: ChatAttachmentNotice) -> Color {
        switch notice.severity {
        case .progress:
            Color(nsColor: .controlBackgroundColor)
        case .warning:
            Color.orange.opacity(0.06)
        case .error:
            Color.orange.opacity(0.10)
        }
    }

    private func noticeBorder(for notice: ChatAttachmentNotice) -> Color {
        switch notice.severity {
        case .progress:
            Color(nsColor: .separatorColor)
        case .warning:
            Color.orange.opacity(0.22)
        case .error:
            Color.orange.opacity(0.34)
        }
    }
}
