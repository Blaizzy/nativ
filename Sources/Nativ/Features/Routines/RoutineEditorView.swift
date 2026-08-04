import SwiftUI

struct RoutineEditor: View {
    let draft: RoutineDraft
    let availableModelIDs: [String]
    let onSave: (Routine) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var modelID: String
    @State private var triggerKind: RoutineTriggerKind
    @State private var weekdays: Set<Int>
    @State private var time: Date
    @State private var kitID: String?
    @State private var notifyOnFinish: Bool

    init(
        draft: RoutineDraft,
        availableModelIDs: [String],
        onSave: @escaping (Routine) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.availableModelIDs = availableModelIDs
        self.onSave = onSave
        self.onCancel = onCancel

        let routine = draft.routine
        _name = State(initialValue: routine.name)
        _instructions = State(initialValue: routine.instructions)
        _modelID = State(initialValue: routine.modelID)
        _triggerKind = State(initialValue: routine.triggerKind)
        _weekdays = State(initialValue: routine.schedule.weekdays)
        var components = DateComponents()
        components.hour = routine.schedule.hour
        components.minute = routine.schedule.minute
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _kitID = State(initialValue: routine.kitID)
        _notifyOnFinish = State(initialValue: routine.notifyOnFinish)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !modelID.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "New routine" : name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Divider()

            Form {
                Section("Name") {
                    TextField("Routine name", text: $name)
                }
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 120)
                        .font(.body)
                }
                Section("Model") {
                    Picker("Model", selection: $modelID) {
                        Text("Select a model").tag("")
                        ForEach(availableModelIDs, id: \.self) { id in
                            Text(NativFormatting.truncateModelName(id, maxLength: 42)).tag(id)
                        }
                    }
                    .labelsHidden()
                }
                Section("Trigger") {
                    Picker("Trigger", selection: $triggerKind) {
                        Text("Schedule").tag(RoutineTriggerKind.schedule)
                        Text("API request").tag(RoutineTriggerKind.api)
                    }
                    .pickerStyle(.segmented)
                    if triggerKind == .schedule {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        weekdayPicker
                    } else {
                        Text("Trigger with POST /v1/routines/\(draft.routine.id)/run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("Capabilities") {
                    Picker("Kit", selection: $kitID) {
                        Text("None").tag(String?.none)
                        ForEach(NativKit.all) { kit in
                            Text(kit.name).tag(String?.some(kit.id))
                        }
                    }
                    .labelsHidden()
                    if let kitID, let kit = NativKit.all.first(where: { $0.id == kitID }) {
                        Text(kit.inventory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Notify me when this routine finishes", isOn: $notifyOnFinish)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(makeRoutine())
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(minWidth: 540, minHeight: 620)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { weekday in
                let symbol = Calendar.current.veryShortWeekdaySymbols[weekday - 1]
                let isOn = weekdays.contains(weekday)
                Button(symbol) {
                    if isOn { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? Color.accentColor : Color.secondary)
            }
            Spacer()
            Text(weekdays.isEmpty ? "Every day" : "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeRoutine() -> Routine {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = RoutineSchedule(
            weekdays: weekdays,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0
        )
        var routine = draft.routine
        routine.name = name.trimmingCharacters(in: .whitespaces)
        routine.instructions = instructions
        routine.modelID = modelID
        routine.triggerKind = triggerKind
        routine.schedule = schedule
        routine.kitID = kitID
        routine.notifyOnFinish = notifyOnFinish
        return routine
    }
}

struct RoutineDetailView: View {
    let routine: Routine
    let runs: [RoutineRun]
    let onRunNow: () -> Void
    let onOpenSession: (UUID) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var scheduledRuns: [RoutineRun] {
        runs.filter { $0.source != .manual }
    }

    private var manualRuns: [RoutineRun] {
        runs.filter { $0.source == .manual }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                        .font(.headline)
                    Text(RoutineFormatting.summary(routine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run now", action: onRunNow)
                    .buttonStyle(.borderedProminent)
                Button("Edit", action: onEdit)
                Menu {
                    Button("Delete routine", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Instructions") {
                        Text(routine.instructions.isEmpty ? "No instructions." : routine.instructions)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    runsSection("Scheduled", scheduledRuns)
                    runsSection("Manual", manualRuns)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 540, minHeight: 560)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    @ViewBuilder
    private func runsSection(_ title: String, _ items: [RoutineRun]) -> some View {
        section("\(title) runs") {
            if items.isEmpty {
                Text("No runs yet.").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { run in
                        RoutineRunRow(run: run, onOpen: {
                            if let sessionID = run.sessionID { onOpenSession(sessionID) }
                        })
                    }
                }
            }
        }
    }
}

private struct RoutineRunRow: View {
    let run: RoutineRun
    let onOpen: () -> Void

    private var statusColor: Color {
        switch run.status {
        case .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                if !run.resultSummary.isEmpty {
                    Text(run.resultSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if run.sessionID != nil {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }
}
