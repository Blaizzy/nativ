import SwiftUI

struct ScheduledRunItem: Identifiable {
    let run: RoutineRun
    let task: Routine

    var id: String { run.id }
}

struct ScheduledSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}

struct ScheduledTaskCard: View {
    let task: Routine
    let latestRun: RoutineRun?
    let isRunning: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onEdit: () -> Void
    let onRun: () -> Void
    let onToggleEnabled: () -> Void
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isSelecting {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .accessibilityLabel("Select \(task.name.isEmpty ? "Untitled scheduled task" : task.name)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }

            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 14) {
                    statusIcon

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            Text(task.name.isEmpty ? "Untitled scheduled task" : task.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            if isRunning {
                                Text("Running")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }

                        Text(task.instructions)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 7) {
                            if task.runsOnSchedule {
                                metadata(
                                    RoutineFormatting.summary(task),
                                    systemImage: "calendar"
                                )
                            }
                            metadata(modelName, systemImage: "cube")
                            if !task.capabilities.isEmpty {
                                metadata(
                                    "\(task.capabilities.count) tool\(task.capabilities.count == 1 ? "" : "s")",
                                    systemImage: "sparkles"
                                )
                            }
                            if let latestRun {
                                metadata(
                                    ScheduledTaskFormatting.runTime(latestRun.startedAt),
                                    systemImage: latestRun.status.systemImage
                                )
                            }
                        }
                    }

                    Spacer(minLength: 16)
                }
                .padding(.leading, isSelecting ? 0 : 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                taskActions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 16)
        }
        .scheduledPanelStyle(isHighlighted: isHovering)
        .contextMenu {
            taskActions
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    @ViewBuilder
    private var taskActions: some View {
        Button("Run now", systemImage: "play", action: onRun)
            .disabled(isRunning)
        Button(
            task.isEnabled ? "Pause" : "Resume",
            systemImage: task.isEnabled ? "pause.circle" : "play.circle",
            action: onToggleEnabled
        )
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }

    private var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    task.isEnabled
                        ? Color.accentColor.opacity(0.14)
                        : Color.secondary.opacity(0.1)
                )
            Image(systemName: task.isEnabled ? "clock.fill" : "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(task.isEnabled ? Color.accentColor : Color.secondary)
        }
        .frame(width: 36, height: 36)
    }

    private var modelName: String {
        NativFormatting.truncateModelName(task.modelID, maxLength: 28)
    }

    private func metadata(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ScheduledRunRow: View {
    let item: ScheduledRunItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: item.run.status.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.run.status.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(item.task.name.isEmpty ? "Untitled scheduled task" : item.task.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(item.run.source.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.run.resultSummary.isEmpty ? item.run.status.title : item.run.resultSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(ScheduledTaskFormatting.runTime(item.run.startedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if item.run.sessionID != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item.run.sessionID == nil)
    }
}

struct ScheduledTasksEmptyState: View {
    let onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No scheduled tasks", systemImage: "clock.badge.checkmark")
        } description: {
            Text("Create a task to run a prompt automatically on a recurring schedule.")
        } actions: {
            Button("New scheduled task", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
    }
}

enum ScheduledTaskFormatting {
    static func runTime(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension RoutineRunStatus {
    var title: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Completed"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }
}

extension RoutineRunSource {
    var title: String {
        switch self {
        case .scheduled: "Scheduled"
        case .manual: "Manual"
        case .api: "API"
        }
    }
}

extension View {
    func scheduledPanelStyle(isHighlighted: Bool = false) -> some View {
        background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    if isHighlighted {
                        Color.primary.opacity(0.045)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isHighlighted
                        ? Color.primary.opacity(0.16)
                        : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        }
    }
}
