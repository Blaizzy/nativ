import Foundation

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
            return "Automation configured"
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
