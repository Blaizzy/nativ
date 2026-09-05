import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    var bulkSelectionBar: some View {
        HStack(spacing: 6) {
            Text(bulkSelectionTitle)
                .nativTextStyle(.supporting)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                bulkTogglePinSelected()
            } label: {
                Image(systemName: allSelectedPinned ? "pin.slash" : "pin")
                    .frame(width: 24, height: 22)
            }
            .help(allSelectedPinned ? "Unpin selected" : "Pin selected")
            .disabled(!hasSelectedPinnable)

            Button {
                bulkExportSelected()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 24, height: 22)
            }
            .help("Export selected")
            .disabled(!hasSelectedChats)

            Button(role: .destructive) {
                isConfirmingBulkDelete = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 22)
            }
            .help("Delete selected")
            .disabled(selectedRecentIDs.isEmpty && selectedFolderIDs.isEmpty)

            Button("Done") {
                withAnimation(.snappy(duration: 0.2)) {
                    exitSelectMode()
                }
            }
            .nativTextStyle(.supportingEmphasized)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    var issueReportMenu: some View {
        footerControl(.reportIssue, tooltip: "Report an Issue") {
            Menu {
                ForEach(IssueReportCategory.allCases) { category in
                    Button {
                        reportIssue(category: category)
                    } label: {
                        Label(category.displayName, systemImage: category.systemImage)
                    }
                }
            } label: {
                footerIcon(systemName: "ladybug")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .foregroundStyle(.secondary)
        }
    }

    var settingsButton: some View {
        footerControl(.settings, tooltip: "Settings") {
            Button {
                applySidebarSelection(.tab(.settings))
            } label: {
                footerIcon(systemName: "gearshape")
            }
            .buttonStyle(.plain)
        }
    }

    var serverToggleButton: some View {
        footerControl(
            .server,
            tooltip: chromeState.isRunning ? "Stop Server" : "Start Server"
        ) {
            Button {
                model.toggleServer()
            } label: {
                footerIcon(systemName: chromeState.isRunning ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(chromeState.modelSwitchInProgress)
        }
    }

    var supportButton: some View {
        footerControl(.support, tooltip: "Star Nativ on GitHub") {
            Button {
                guard let url = URL(string: "https://github.com/Blaizzy/nativ") else {
                    return
                }
                NSWorkspace.shared.open(url)
            } label: {
                footerIcon(
                    systemName: hoveredFooterControl == .support ? "heart.fill" : "heart"
                )
            }
            .buttonStyle(.plain)
        }
    }

    func footerIcon(
        systemName: String
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    func footerControl<Content: View>(
        _ control: FooterControl,
        tooltip: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 40, height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hoveredFooterControl == control ? 0.08 : 0))
            }
            .overlay {
                FooterControlTrackingView(
                    tooltip: tooltip,
                    onHover: { isHovering in
                        updateFooterHover(control, isHovering: isHovering)
                    }
                )
            }
            .contentShape(Rectangle())
            .accessibilityLabel(tooltip)
            .animation(.easeOut(duration: 0.12), value: hoveredFooterControl == control)
    }

    func updateFooterHover(_ control: FooterControl, isHovering: Bool) {
        if isHovering {
            hoveredFooterControl = control
        } else if hoveredFooterControl == control {
            hoveredFooterControl = nil
        }
    }

    func reportIssue(category: IssueReportCategory) {
        let body = IssueReportBuilder.markdown(
            category: category,
            details: "",
            sections: IssueDiagnostics.collect(category: category, model: model, runtime: runtime),
            serverOutput: IssueDiagnostics.serverOutputTail(model: model)
        )
        let clipboard =
            (category == .crash ? IssueDiagnostics.latestCrashRawReport() : nil)
            ?? (body.count > IssueReportBuilder.urlBodyCharacterBudget ? body : nil)
        if let clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
        }
        guard
            let url = IssueReportBuilder.githubIssueURL(
                title: "",
                label: category.githubLabel,
                body: body
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

}

private struct FooterControlTrackingView: NSViewRepresentable {
    let tooltip: String
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> FooterControlTrackingNSView {
        FooterControlTrackingNSView(tooltip: tooltip, onHover: onHover)
    }

    func updateNSView(_ view: FooterControlTrackingNSView, context: Context) {
        view.toolTip = tooltip
        view.onHover = onHover
    }
}

@MainActor
private final class FooterControlTrackingNSView: NSView {
    var onHover: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(tooltip: String, onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: .zero)
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }
}
