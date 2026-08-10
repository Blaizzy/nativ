import SwiftUI

struct DevHubView: View {
    enum Section: String, CaseIterable, Identifiable {
        case integrations = "Integrations"
        case developer = "Developer"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .integrations:
                "puzzlepiece.extension"
            case .developer:
                "hammer"
            }
        }
    }

    @Binding var section: Section
    @ObservedObject var model: NativModel
    @ObservedObject var runtime: SystemRuntimeMonitor
    @Binding var showsConfiguration: Bool

    var body: some View {
        HStack(spacing: 0) {
            subnav
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subnav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .frame(width: 18)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                    .background(
                        section == item ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 188)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .integrations:
            IntegrationsView(model: model)
        case .developer:
            DeveloperView(
                model: model,
                runtime: runtime,
                showsConfiguration: $showsConfiguration
            )
        }
    }
}
