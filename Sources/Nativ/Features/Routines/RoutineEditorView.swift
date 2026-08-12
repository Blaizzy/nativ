import SwiftUI

struct RoutineEditor: View {
    let draft: RoutineDraft
    let availableModelIDs: [String]
    let onSave: (Routine) -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)?

    @State private var name: String
    @State private var instructions: String
    @State private var modelID: String
    @State private var triggerKind: RoutineTriggerKind
    @State private var weekdays: Set<Int>
    @State private var time: Date
    @State private var kitID: String?
    @State private var notifyOnFinish: Bool
    @State private var isConfirmingDelete = false

    init(
        draft: RoutineDraft,
        availableModelIDs: [String],
        onSave: @escaping (Routine) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.draft = draft
        self.availableModelIDs = availableModelIDs
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete

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
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "New routine" : name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        isConfirmingDelete = true
                    }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("Name") {
                        TextField("Routine name", text: $name)
                            .textFieldStyle(.plain)
                    }
                    field("Instructions") {
                        TextEditor(text: $instructions)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 130)
                            .font(.body)
                    }
                    field("Model") {
                        Picker("Model", selection: $modelID) {
                            Text("Select a model").tag("")
                            ForEach(availableModelIDs, id: \.self) { id in
                                Text(NativFormatting.truncateModelName(id, maxLength: 42)).tag(id)
                            }
                        }
                        .labelsHidden()
                    }
                    field("Trigger") { triggerContent }
                    field("Capabilities") {
                        VStack(alignment: .leading, spacing: 10) {
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
                    }
                    box {
                        Toggle("Notify me when this routine finishes", isOn: $notifyOnFinish)
                    }
                }
                .padding(20)
            }

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
        .alert("Delete routine?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This routine and its schedule will be permanently deleted.")
        }
    }

    @ViewBuilder
    private var triggerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Trigger", selection: $triggerKind) {
                Text("Schedule").tag(RoutineTriggerKind.schedule)
                Text("API request").tag(RoutineTriggerKind.api)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if triggerKind == .schedule {
                Divider()
                HStack {
                    Text("Time")
                    Spacer()
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                weekdayPicker
            } else {
                Divider()
                Text("Runs when this routine's endpoint receives a POST request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            box { content() }
        }
    }

    @ViewBuilder
    private func box<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
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
