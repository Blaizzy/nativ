import SwiftUI

private enum ScheduledTaskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"

    var id: Self { self }
}

struct ScheduledTasksView: View {
    @ObservedObject var model: NativModel
    @ObservedObject var mcpHost: MCPHostManager
    @ObservedObject var extensionManager: NativExtensionManager
    var titleLeadingInset: CGFloat = 0
    let onOpenRun: (UUID) -> Void
    let onDeleteSessions: (Set<UUID>) -> Void

    @ObservedObject private var store = RoutineStore.shared
    @StateObject private var modelLibrary = LocalModelLibrary()
    @State private var draft: RoutineDraft?
    @State private var pendingDeletion: Routine?
    @State private var filter: ScheduledTaskFilter = .all

    private var orderedTasks: [Routine] {
        store.routines.sorted {
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
            return $0.createdAt > $1.createdAt
        }
    }

    private var filteredTasks: [Routine] {
        switch filter {
        case .all:
            orderedTasks
        case .active:
            orderedTasks.filter(\.isEnabled)
        case .paused:
            orderedTasks.filter { !$0.isEnabled }
        }
    }

    private var recentRuns: [ScheduledRunItem] {
        store.runs
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(12)
            .compactMap { run in
                store.routine(id: run.routineID).map {
                    ScheduledRunItem(run: run, task: $0)
                }
            }
    }

    var body: some View {
        HStack(spacing: 0) {
            taskBrowser
                .frame(
                    minWidth: draft == nil ? 0 : 320,
                    idealWidth: draft == nil ? nil : 380,
                    maxWidth: draft == nil ? .infinity : 440
                )

            if let draft {
                Divider()
                editor(for: draft)
                    .id(draft.id)
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: draft?.id)
        .background(Color.nativMainContentBackground)
        .alert(
            "Delete scheduled task?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { task in
            Button("Delete", role: .destructive) {
                delete(task)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This scheduled task and its run history will be permanently deleted.")
        }
    }

    private var taskBrowser: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if orderedTasks.isEmpty {
                ScheduledTasksEmptyState(onCreate: presentNewTask)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                taskList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduled")
                    .font(.title2.weight(.semibold))
                Text("Review recurring tasks and their latest runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: presentNewTask) {
                if draft == nil {
                    Label("New scheduled task", systemImage: "plus")
                } else {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("New scheduled task")
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    filterBar

                    if filteredTasks.isEmpty {
                        ContentUnavailableView(
                            "No \(filter.rawValue.lowercased()) scheduled tasks",
                            systemImage: filter == .active ? "clock" : "pause.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(filteredTasks) { task in
                                taskCard(task)
                            }
                        }
                    }
                }

                if !recentRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ScheduledSectionHeader(
                            title: "Recent runs",
                            count: recentRuns.count
                        )
                        VStack(spacing: 0) {
                            ForEach(Array(recentRuns.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                ScheduledRunRow(item: item) {
                                    if let sessionID = item.run.sessionID {
                                        onOpenRun(sessionID)
                                    }
                                }
                            }
                        }
                        .scheduledPanelStyle()
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(ScheduledTaskFilter.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        filter = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(filter == option ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background {
                            if filter == option {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
    }

    private func taskCard(_ task: Routine) -> some View {
        let runs = store.runs(forRoutine: task.id)
        return ScheduledTaskCard(
            task: task,
            latestRun: runs.first,
            isRunning: runs.contains { $0.status == .running },
            onEdit: { presentEditor(for: task) },
            onRun: { RoutineRunCoordinator.shared.run(task, source: .manual) },
            onToggleEnabled: {
                store.setEnabled(!task.isEnabled, id: task.id)
            },
            onDelete: { pendingDeletion = task }
        )
    }

    private func presentNewTask() {
        prepareEditor()
        draft = RoutineDraft(
            routine: Routine(modelID: model.settings.normalized().languageModelID ?? "")
        )
    }

    private func presentEditor(for task: Routine) {
        prepareEditor()
        draft = RoutineDraft(routine: task)
    }

    private func prepareEditor() {
        let settings = model.settings.normalized()
        modelLibrary.scan(searchPaths: settings.localModelSearchPaths)
        mcpHost.reload(servers: settings.mcpServers)
    }

    @ViewBuilder
    private func editor(for draft: RoutineDraft) -> some View {
        let textModels = modelLibrary.models.filter { $0.isEligibleForLanguageModelPicker }
        let modelIDs = textModels.map(\.repoID)
        let selectedModelID = draft.routine.modelID
        let availableModelIDs = (
            selectedModelID.isEmpty || modelIDs.contains(selectedModelID)
                ? modelIDs
                : modelIDs + [selectedModelID]
        ).sorted()
        let toolCapableModelIDs = Set(
            textModels.filter { $0.capabilities.contains(.tools) }.map(\.repoID)
        )
        let isExisting = store.routine(id: draft.routine.id) != nil

        RoutineEditor(
            draft: draft,
            availableModelIDs: availableModelIDs,
            toolCapableModelIDs: toolCapableModelIDs,
            model: model,
            mcpHost: mcpHost,
            isExistingTask: isExisting,
            onSave: { task in
                save(task)
                self.draft = nil
            },
            onCancel: { self.draft = nil }
        )
    }

    private func save(_ task: Routine) {
        enableNewKits(in: task)
        let linkedTask = ScheduledTaskChatLinker.ensureChat(
            for: task,
            runs: store.runs(forRoutine: task.id),
            sessionStore: ChatSessionStore()
        )
        store.upsert(linkedTask)
        NotificationCenter.default.post(name: .routineDidSaveChatSession, object: nil)
    }

    private func enableNewKits(in task: Routine) {
        let previousCapabilities = store.routine(id: task.id)?.capabilities ?? []
        let previousKitIDs = Set(previousCapabilities.compactMap { capability -> String? in
            guard case .kit(let id) = capability else { return nil }
            return id
        })

        for capability in task.capabilities {
            guard case .kit(let id) = capability,
                  !previousKitIDs.contains(id),
                  let kit = NativKit.all.first(where: { $0.id == id })
            else { continue }
            NativKitActivation.setEnabled(
                true,
                kit: kit,
                model: model,
                manager: extensionManager
            )
        }
    }

    private func delete(_ task: Routine) {
        let sessionIDs = Set(
            [task.sourceSessionID].compactMap { $0 }
                + store.runs(forRoutine: task.id).compactMap(\.sessionID)
        )
        store.delete(id: task.id)
        if draft?.id == task.id {
            draft = nil
        }
        onDeleteSessions(sessionIDs)
    }
}
