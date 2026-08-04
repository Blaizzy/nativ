import SwiftUI

struct RoutinesView: View {
    @ObservedObject var model: NativModel
    @ObservedObject private var store = RoutineStore.shared
    @StateObject private var localLibrary = LocalModelLibrary()

    var onOpenSession: (UUID) -> Void = { _ in }

    @State private var showsCalendar = false
    @State private var editing: RoutineDraft?
    @State private var detail: Routine?
    @State private var draftText = ""
    @State private var designerModelID = ""
    @State private var isDrafting = false
    @State private var draftError: String?

    private var availableModelIDs: [String] {
        localLibrary.models
            .filter { $0.capabilities.contains(.text) }
            .map(\.repoID)
            .sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                designerSection
                Picker("View", selection: $showsCalendar) {
                    Text("List").tag(false)
                    Text("Calendar").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if store.routines.isEmpty {
                    emptyState
                } else if showsCalendar {
                    calendar
                } else {
                    list
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .background(Color.nativMainContentBackground)
        .task(id: model.settings.modelSearchPath) {
            localLibrary.scan(
                path: model.settings.modelSearchPath,
                additionalPaths: model.settings.normalized().additionalModelSearchPaths
            )
        }
        .onChange(of: localLibrary.models.count) { _, _ in
            if designerModelID.isEmpty {
                designerModelID = availableModelIDs.first ?? ""
            }
        }
        .onAppear {
            if designerModelID.isEmpty {
                designerModelID = availableModelIDs.first ?? ""
            }
        }
        .sheet(item: $editing) { draft in
            RoutineEditor(
                draft: draft,
                availableModelIDs: availableModelIDs,
                onSave: { routine in
                    store.upsert(routine)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .sheet(item: $detail) { routine in
            RoutineDetailView(
                routine: routine,
                runs: store.runs(forRoutine: routine.id),
                onRunNow: { RoutineRunCoordinator.shared.run(routine, source: .manual) },
                onOpenSession: onOpenSession,
                onEdit: {
                    detail = nil
                    editing = RoutineDraft(routine: routine)
                },
                onDelete: {
                    store.delete(id: routine.id)
                    detail = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Routines", systemImage: "bolt")
                    .font(.title2.weight(.semibold))
                Text("Run a prompt on a schedule or from an API request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editing = RoutineDraft(routine: Routine())
            } label: {
                Label("New routine", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var designerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What do you want to automate?", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Picker("Designer model", selection: $designerModelID) {
                    Text("Model").tag("")
                    ForEach(availableModelIDs, id: \.self) { id in
                        Text(NativFormatting.truncateModelName(id, maxLength: 28)).tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                if isDrafting {
                    ProgressView().controlSize(.small)
                }
                Button("Draft routine", action: draftRoutine)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || designerModelID.isEmpty
                            || isDrafting
                    )
            }

            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { draftText = suggestion }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let draftError {
                Text(draftError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private static let suggestions = [
        "Summarize my unread notes every weekday morning",
        "Give me five dinner ideas every evening",
        "Draft a daily standup update at 9am",
    ]

    private func draftRoutine() {
        let text = draftText
        let designer = designerModelID
        isDrafting = true
        draftError = nil
        Task { @MainActor in
            let routine = await RoutineDrafter.draft(
                description: text,
                designerModelID: designer,
                model: model
            )
            isDrafting = false
            if let routine {
                draftText = ""
                editing = RoutineDraft(routine: routine)
            } else {
                draftError = "Couldn't draft a routine from that. Try rephrasing, or create one manually."
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.badge.clock")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No routines yet")
                .font(.headline)
            Text("Create a routine to run a prompt automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var list: some View {
        VStack(spacing: 10) {
            ForEach(store.routines) { routine in
                RoutineRow(
                    routine: routine,
                    onToggleEnabled: { store.setEnabled($0, id: routine.id) },
                    onRunNow: { RoutineRunCoordinator.shared.run(routine, source: .manual) },
                    onOpen: { detail = routine }
                )
            }
        }
    }

    private var calendar: some View {
        VStack(spacing: 8) {
            ForEach(1...7, id: \.self) { weekday in
                let dayRoutines = store.routines.filter {
                    $0.isEnabled && $0.runsOnSchedule
                        && ($0.schedule.runsEveryDay || $0.schedule.weekdays.contains(weekday))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Calendar.current.weekdaySymbols[weekday - 1])
                        .font(.callout.weight(.semibold))
                    if dayRoutines.isEmpty {
                        Text("—").foregroundStyle(.tertiary).font(.caption)
                    } else {
                        ForEach(dayRoutines) { routine in
                            HStack {
                                Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                                Spacer()
                                Text(RoutineFormatting.timeString(routine.schedule))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct RoutineRow: View {
    let routine: Routine
    let onToggleEnabled: (Bool) -> Void
    let onRunNow: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                    .font(.body.weight(.medium))
                Text(RoutineFormatting.summary(routine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Run now", action: onRunNow)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Toggle("", isOn: Binding(get: { routine.isEnabled }, set: onToggleEnabled))
                .labelsHidden()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }
}

enum RoutineFormatting {
    static func timeString(_ schedule: RoutineSchedule) -> String {
        var components = DateComponents()
        components.hour = schedule.hour
        components.minute = schedule.minute
        guard let date = Calendar.current.date(from: components) else {
            return ""
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func summary(_ routine: Routine) -> String {
        guard routine.runsOnSchedule else {
            return "Runs on API request"
        }
        let time = timeString(routine.schedule)
        if routine.schedule.runsEveryDay {
            return "Every day at \(time)"
        }
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = routine.schedule.weekdays.sorted()
            .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            .joined(separator: ", ")
        return days.isEmpty ? "Not scheduled" : "\(days) at \(time)"
    }
}

final class RoutineDraft: Identifiable {
    let id: String
    var routine: Routine

    init(routine: Routine) {
        self.id = routine.id
        self.routine = routine
    }
}
